import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "PrayTimes.js" as PrayTimes

// The Salati popup: a hero countdown to the next prayer, then today's six
// times. Sunrise is informational; the next prayer is the only highlighted
// row, and rows already passed are dimmed. Informational rows do not respond
// to clicks.
//
// Prayer times come from AlAdhan.com using coordinates detected from the
// network (auto), configured by hand (manual), or from the bundled PrayTimes
// engine (offline / any network failure). Nothing is fetched until the panel
// is opened, and at most three network calls are made per local day.
Panel {
  id: root
  moduleName: "muhamed.salati"
  ipcTarget: "muhamed.salati"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget, not this nested panel, as the popout identity.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property color contentForeground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Settings (injected by BarWidget) --------------------------------
  readonly property string locationMode: {
    var value = String(root.setting("locationMode", "auto"))
    return (value === "manual" || value === "offline") ? value : "auto"
  }
  readonly property real latitude: {
    var value = parseFloat(String(root.setting("latitude", "24.7136")))
    return isFinite(value) ? value : NaN
  }
  readonly property real longitude: {
    var value = parseFloat(String(root.setting("longitude", "46.6753")))
    return isFinite(value) ? value : NaN
  }
  readonly property bool hasValidCoordinates: isFinite(root.latitude)
    && isFinite(root.longitude)
    && root.latitude >= -90 && root.latitude <= 90
    && root.longitude >= -180 && root.longitude <= 180

  readonly property string methodKey: {
    var value = String(root.setting("calculationMethod", "umm_al_qura"))
    return PrayTimes.methodKeys().indexOf(value) >= 0 ? value : "umm_al_qura"
  }
  readonly property string madhabKey: root.setting("madhab", "standard") === "hanafi"
    ? "hanafi" : "standard"

  // AlAdhan method identifiers. Passed explicitly on every request: omitting
  // them lets the service geo-pick a method the user never chose.
  readonly property int aladhanMethod: {
    var ids = {
      umm_al_qura: 4,
      muslim_world_league: 3,
      isna: 2,
      egypt: 5,
      karachi: 1
    }
    var id = ids[root.methodKey]
    return id === undefined ? 4 : id
  }

  // ---- Clock and schedule ----------------------------------------------
  property date now: new Date()
  property var times: ({})
  property var tomorrowTimes: ({})

  // Day the displayed table belongs to, as dd-MM-yyyy (the wire format).
  property string timesDate: ""
  // "auto" | "manual" | "offline": which source produced the displayed table.
  property string observedSource: "offline"
  // Wall-clock milliseconds of the last successful AlAdhan response.
  property real lastFetchMs: 0
  property bool networkFailed: false

  readonly property real nowSeconds: {
    var current = root.now
    var midnight = new Date(current.getFullYear(), current.getMonth(), current.getDate())
    return Math.max(0, (current.getTime() - midnight.getTime()) / 1000)
  }

  readonly property var rows: {
    var table = root.times || ({})
    return [
      { key: "fajr",    label: strings.t("prayer.fajr"),    minutes: table.fajr },
      { key: "sunrise", label: strings.t("prayer.sunrise"), minutes: table.sunrise },
      { key: "dhuhr",   label: strings.t("prayer.dhuhr"),   minutes: table.dhuhr },
      { key: "asr",     label: strings.t("prayer.asr"),     minutes: table.asr },
      { key: "maghrib", label: strings.t("prayer.maghrib"), minutes: table.maghrib },
      { key: "isha",    label: strings.t("prayer.isha"),    minutes: table.isha }
    ]
  }

  // The next prayer still ahead today, for the row highlight. Sunrise is not
  // a prayer and is never picked. After Isha this is empty: the highlighted
  // row would otherwise be today's already-passed Fajr.
  readonly property string nextKey: {
    var table = root.times || ({})
    if (table.valid !== true) return ""
    var keys = ["fajr", "dhuhr", "asr", "maghrib", "isha"]
    for (var i = 0; i < keys.length; i++) {
      var minutes = table[keys[i]]
      if (isFinite(minutes) && root.nowSeconds < minutes * 60) return keys[i]
    }
    return ""
  }

  // The next prayer for the countdown, which keeps running after Isha against
  // tomorrow's Fajr (tomorrow's table is fetched with today's).
  readonly property var nextInfo: {
    var table = root.times || ({})
    if (table.valid !== true) return null
    var keys = ["fajr", "dhuhr", "asr", "maghrib", "isha"]
    for (var i = 0; i < keys.length; i++) {
      var minutes = table[keys[i]]
      if (isFinite(minutes) && root.nowSeconds < minutes * 60)
        return { key: keys[i], target: minutes * 60 }
    }
    var tomorrow = root.tomorrowTimes || ({})
    if (isFinite(tomorrow.fajr))
      return { key: "fajr", target: 86400 + tomorrow.fajr * 60 }
    return null
  }

  readonly property string countdownText: {
    var info = root.nextInfo
    if (!info) return "—"
    var remaining = Math.max(0, Math.floor(info.target - root.nowSeconds))
    var hours = Math.floor(remaining / 3600)
    var minutes = Math.floor((remaining % 3600) / 60)
    var seconds = remaining % 60
    return hours + ":" + root.pad2(minutes) + ":" + root.pad2(seconds)
  }

  readonly property string untilLabel: {
    var info = root.nextInfo
    if (!info) return ""
    return strings.t("panel.until").arg(strings.t("prayer." + info.key))
  }

  readonly property string footerText: {
    if (root.observedSource === "auto") return strings.t("panel.source")
    if (root.observedSource === "manual") return strings.t("panel.sourceManual")
    return strings.t("panel.sourceOffline")
  }

  function pad2(value) {
    return value < 10 ? "0" + value : String(value)
  }

  function formatTime(minutes) {
    if (!isFinite(minutes)) return "—"
    var total = Math.round(minutes) % 1440
    if (total < 0) total += 1440
    return root.pad2(Math.floor(total / 60)) + ":" + root.pad2(total % 60)
  }

  function isPast(minutes) {
    return isFinite(minutes) && root.nowSeconds >= minutes * 60
  }

  // ---- Day stamps ------------------------------------------------------
  // dd-MM-yyyy is what AlAdhan takes and echoes back; sending ISO dates is
  // silently misparsed by the service, so never build a request from one.
  function apiDate(date) {
    return Qt.formatDate(date, "dd-MM-yyyy")
  }

  function dayStamp(date) {
    return Qt.formatDate(date, "yyyy-MM-dd")
  }

  // ---- Async state -----------------------------------------------------
  property bool refreshInFlight: false
  property real detectedLatitude: NaN
  property real detectedLongitude: NaN
  readonly property bool hasDetectedCoordinates: isFinite(root.detectedLatitude)
    && isFinite(root.detectedLongitude)
    && root.detectedLatitude >= -90 && root.detectedLatitude <= 90
    && root.detectedLongitude >= -180 && root.detectedLongitude <= 180
  property string geoDay: ""

  property real requestLatitude: NaN
  property real requestLongitude: NaN
  property string requestTodayDate: ""
  property string requestTomorrowDate: ""
  property int pendingTimings: 0
  property bool todayFailed: false

  // ---- Parsing and validation ------------------------------------------
  // Only these two shapes ever reach the UI: validated "HH:MM" strings turned
  // into minute numbers, and fixed localized labels. Raw response bytes are
  // never rendered.
  function parseClock(value) {
    if (typeof value !== "string") return NaN
    if (!/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(value)) return NaN
    return parseInt(value.slice(0, 2), 10) * 60 + parseInt(value.slice(3), 10)
  }

  function parseTimings(raw, expectedDate) {
    var text = String(raw || "").trim()
    if (text.length === 0 || text.length > 65536) return null
    var data
    try {
      data = JSON.parse(text)
    } catch (error) {
      return null
    }
    var payload = data && data.data
    if (!payload) return null
    // AlAdhan nests the date under data.date.gregorian; some mirrors and the
    // documented shape put it directly at data.gregorian. Accept either, but
    // still insist the echoed date is exactly the one requested.
    var gregorian = payload.gregorian
      || (payload.date && payload.date.gregorian)
    if (!gregorian || String(gregorian.date) !== expectedDate) return null
    var timings = payload.timings
    if (!timings) return null

    var out = {
      fajr: root.parseClock(timings.Fajr),
      sunrise: root.parseClock(timings.Sunrise),
      dhuhr: root.parseClock(timings.Dhuhr),
      asr: root.parseClock(timings.Asr),
      maghrib: root.parseClock(timings.Maghrib),
      isha: root.parseClock(timings.Isha)
    }
    if (!isFinite(out.fajr) || !isFinite(out.sunrise) || !isFinite(out.dhuhr)
        || !isFinite(out.asr) || !isFinite(out.maghrib) || !isFinite(out.isha))
      return null
    out.valid = true
    return out
  }

  // geo.omarchy.org and ipwho.is both answer with decimal-degree latitude and
  // longitude. Their names and timezone strings are ignored: only the numbers
  // reach the timings request, and only after a range check.
  function parseGeo(raw) {
    var text = String(raw || "").trim()
    if (text.length === 0 || text.length > 65536) return null
    var data
    try {
      data = JSON.parse(text)
    } catch (error) {
      return null
    }
    var latitude = Number(data && data.latitude)
    var longitude = Number(data && data.longitude)
    if (!isFinite(latitude) || !isFinite(longitude)
        || latitude < -90 || latitude > 90
        || longitude < -180 || longitude > 180) return null
    return { latitude: latitude, longitude: longitude }
  }

  function timingsUrl(date, latitude, longitude) {
    return "https://api.aladhan.com/v1/timings/" + date
      + "?latitude=" + encodeURIComponent(String(latitude))
      + "&longitude=" + encodeURIComponent(String(longitude))
      + "&method=" + root.aladhanMethod
      + "&school=" + (root.madhabKey === "hanafi" ? 1 : 0)
  }

  // ---- Local calculation (offline mode and network fallback) -----------
  function computeLocal(date, latitude, longitude) {
    try {
      return PrayTimes.compute(date, latitude, longitude, root.methodKey, root.madhabKey)
    } catch (error) {
      console.warn("Salati: prayer calculation failed:", error)
      return ({})
    }
  }

  // Coordinates for the local engine: last network-detected place in auto
  // mode, else the configured pair, else the built-in Riyadh defaults.
  function fallbackCoordinates() {
    if (root.locationMode === "auto" && root.hasDetectedCoordinates)
      return { latitude: root.detectedLatitude, longitude: root.detectedLongitude }
    if (root.hasValidCoordinates)
      return { latitude: root.latitude, longitude: root.longitude }
    return { latitude: 24.7136, longitude: 46.6753 }
  }

  function applyOffline() {
    var coords = root.fallbackCoordinates()
    var current = new Date()
    var tomorrow = new Date(current.getFullYear(), current.getMonth(), current.getDate() + 1)
    root.now = current
    root.times = root.computeLocal(current, coords.latitude, coords.longitude)
    root.tomorrowTimes = root.computeLocal(tomorrow, coords.latitude, coords.longitude)
    root.timesDate = root.apiDate(current)
    root.observedSource = "offline"
    root.lastFetchMs = 0
    root.refreshInFlight = false
  }

  // ---- Fetch orchestration ---------------------------------------------
  function maybeRefresh() {
    if (root.locationMode === "offline") {
      if (!root.refreshInFlight) root.applyOffline()
      return
    }
    if (root.refreshInFlight) return

    var today = root.apiDate(new Date())
    var fresh = root.times && root.times.valid === true
      && root.timesDate === today
      && root.observedSource !== "offline"
      && (Date.now() - root.lastFetchMs) < 30 * 60 * 1000
    if (fresh) return

    root.refreshInFlight = true
    if (root.locationMode === "manual") {
      root.startTimings(root.latitude, root.longitude)
      return
    }
    if (root.geoDay === root.dayStamp(new Date()) && root.hasDetectedCoordinates) {
      root.startTimings(root.detectedLatitude, root.detectedLongitude)
      return
    }
    root.beginGeoRequest("omarchy")
  }

  function beginGeoRequest(source) {
    root.networkFailed = false
    if (source === "omarchy") {
      geoProc.handled = false
      geoProc.command = ["curl", "-fsSL", "--max-time", "4", "https://geo.omarchy.org/"]
      geoProc.running = true
    } else {
      ipProc.handled = false
      ipProc.command = ["curl", "-fsSL", "--max-time", "4", "https://ipwho.is/"]
      ipProc.running = true
    }
  }

  function handleGeo(source, raw) {
    var coords = root.parseGeo(raw)
    if (coords) {
      root.detectedLatitude = coords.latitude
      root.detectedLongitude = coords.longitude
      root.geoDay = root.dayStamp(new Date())
      root.startTimings(coords.latitude, coords.longitude)
      return
    }
    if (source === "omarchy") {
      root.beginGeoRequest("ipwho")
      return
    }
    // Both lookups failed: use the local engine, never a blank panel.
    root.applyOffline()
  }

  function startTimings(latitude, longitude) {
    if (!isFinite(latitude) || !isFinite(longitude)
        || latitude < -90 || latitude > 90
        || longitude < -180 || longitude > 180) {
      root.applyOffline()
      return
    }

    var current = new Date()
    root.requestLatitude = latitude
    root.requestLongitude = longitude
    root.requestTodayDate = root.apiDate(current)
    root.requestTomorrowDate = root.apiDate(
      new Date(current.getFullYear(), current.getMonth(), current.getDate() + 1))
    root.todayFailed = false
    root.pendingTimings = 0

    {
      root.pendingTimings += 1
      todayProc.handled = false
      todayProc.command = ["curl", "-fsSL", "--max-time", "10",
        root.timingsUrl(root.requestTodayDate, latitude, longitude)]
      todayProc.running = true
    }
    {
      root.pendingTimings += 1
      tomorrowProc.handled = false
      tomorrowProc.command = ["curl", "-fsSL", "--max-time", "10",
        root.timingsUrl(root.requestTomorrowDate, latitude, longitude)]
      tomorrowProc.running = true
    }

    if (root.pendingTimings === 0) {
      // Budget exhausted. Keep a good table for today if we already have one;
      // otherwise compute locally rather than show nothing.
      root.refreshInFlight = false
      if (!(root.times && root.times.valid === true
          && root.timesDate === root.requestTodayDate))
        root.applyOffline()
    }
  }

  function handleTimings(which, raw) {
    if (which === "today") {
      var parsed = root.parseTimings(raw, root.requestTodayDate)
      if (parsed) {
        root.times = parsed
        root.timesDate = root.requestTodayDate
        root.observedSource = root.locationMode === "manual" ? "manual" : "auto"
        root.lastFetchMs = Date.now()
      } else {
        root.todayFailed = true
      }
    } else {
      var parsedTomorrow = root.parseTimings(raw, root.requestTomorrowDate)
      root.tomorrowTimes = parsedTomorrow || ({})
    }

    root.pendingTimings = Math.max(0, root.pendingTimings - 1)
    if (root.pendingTimings === 0) root.finishTimings()
  }

  function finishTimings() {
    if (root.todayFailed || !root.times || root.times.valid !== true) {
      root.networkFailed = true
      root.refreshInFlight = false
      if (!root.times || root.times.valid !== true) root.applyOffline()
      return
    }
    // Today's table is authoritative. If tomorrow's request failed, the local
    // engine still supplies Fajr for the after-Isha countdown.
    if (!root.tomorrowTimes || root.tomorrowTimes.valid !== true) {
      var current = new Date()
      var tomorrow = new Date(current.getFullYear(), current.getMonth(), current.getDate() + 1)
      root.tomorrowTimes = root.computeLocal(tomorrow, root.requestLatitude, root.requestLongitude)
    }
    root.refreshInFlight = false
    root.networkFailed = false
  }

  function refresh() {
    root.lastFetchMs = 0
    if (root.opened) root.maybeRefresh()
  }

  // ---- Lifecycle -------------------------------------------------------
  Component.onCompleted: root.applyOffline()

  onSettingsChanged: {
    root.now = new Date()
    root.lastFetchMs = 0
    if (!root.opened) return
    root.applyOffline()
    root.maybeRefresh()
  }

  // While the popup is visible the clock ticks every second for the countdown
  // and to keep the passed-row dimming exact. Across midnight the local table
  // is rebuilt immediately and, if budget allows, refreshed from the network.
  Timer {
    interval: 1000
    repeat: true
    running: root.opened
    onTriggered: {
      var current = new Date()
      if (root.dayStamp(current) !== root.dayStamp(root.now)) {
        root.applyOffline()
        root.lastFetchMs = 0
        root.maybeRefresh()
      } else {
        root.now = current
      }
    }
  }

  // ---- Panel lifecycle (mirrors omarchy.weather) -----------------------
  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.now = new Date()
    if (!root.times || root.times.valid !== true) root.applyOffline()
    root.maybeRefresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.now = new Date()
    if (!root.times || root.times.valid !== true) root.applyOffline()
    root.maybeRefresh()
    // Set after showing: showing hands the popout coordinator over, which
    // closes whichever panel was open and clears the shared flag.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Network processes ----------------------------------------------
  // Each Process records whether its result was handled so the exit signal
  // and the stream-finished signal cannot both deliver the same response.
  Process {
    id: geoProc
    property bool handled: false
    onRunningChanged: if (running) handled = false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (geoProc.handled) return
        geoProc.handled = true
        root.handleGeo("omarchy", text)
      }
    }
    onExited: function(exitCode) {
      if (geoProc.handled) return
      geoProc.handled = true
      root.handleGeo("omarchy", "")
    }
  }

  Process {
    id: ipProc
    property bool handled: false
    onRunningChanged: if (running) handled = false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (ipProc.handled) return
        ipProc.handled = true
        root.handleGeo("ipwho", text)
      }
    }
    onExited: function(exitCode) {
      if (ipProc.handled) return
      ipProc.handled = true
      root.handleGeo("ipwho", "")
    }
  }

  Process {
    id: todayProc
    property bool handled: false
    onRunningChanged: if (running) handled = false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (todayProc.handled) return
        todayProc.handled = true
        root.handleTimings("today", text)
      }
    }
    onExited: function(exitCode) {
      if (todayProc.handled) return
      todayProc.handled = true
      root.handleTimings("today", "")
    }
  }

  Process {
    id: tomorrowProc
    property bool handled: false
    onRunningChanged: if (running) handled = false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (tomorrowProc.handled) return
        tomorrowProc.handled = true
        root.handleTimings("tomorrow", text)
      }
    }
    onExited: function(exitCode) {
      if (tomorrowProc.handled) return
      tomorrowProc.handled = true
      root.handleTimings("tomorrow", "")
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Anchor under the widget rather than the middle of the bar.
    centerOnBar: false
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      implicitHeight: contentColumn.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: scroll.width
          spacing: Style.space(12)

          // ---- Header ------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(5)

            Text {
              textFormat: Text.PlainText
              text: "\uF186  SALATI"
              color: Commons.Color.accent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 2
            }

            Text {
              textFormat: Text.PlainText
              text: strings.t("panel.title")
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Item { width: 1; height: Style.space(2) }

            Text {
              textFormat: Text.PlainText
              text: new Date(root.now).toLocaleDateString()
              color: Qt.darker(root.contentForeground, 1.35)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Rectangle {
            width: parent.width
            height: Style.space(128)
            radius: Style.space(18)
            color: Style.selectionFillFor(root.contentForeground, Commons.Color.accent)

            Column {
              anchors.centerIn: parent
              spacing: Style.space(4)
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.countdownText
                color: Commons.Color.accent
                font.family: root.contentFontFamily
                font.pixelSize: 48
                font.bold: true
                font.features: ({ "tnum": 1 })
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.untilLabel
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          // ---- Prayer times -----------------------------------------
          Column {
            visible: root.times && root.times.valid === true
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.rows

              Rectangle {
                required property var modelData
                width: parent.width
                height: Style.space(36)
                radius: Style.cornerRadius
                color: modelData.key === root.nextKey
                  ? Style.selectionFillFor(root.contentForeground, Commons.Color.accent)
                  : "transparent"
                opacity: root.isPast(modelData.minutes) ? 0.45 : 1

                Row {
                  id: rowLayout
                  width: parent.width - Style.space(20)
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    id: rowName
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: modelData.key === root.nextKey
                      ? Commons.Color.accent
                      : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: modelData.key === root.nextKey
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Item {
                    width: Math.max(0, rowLayout.width - rowName.implicitWidth
                      - rowTime.implicitWidth - rowLayout.spacing * 2)
                    height: 1
                  }

                  Text {
                    id: rowTime
                    textFormat: Text.PlainText
                    text: root.formatTime(modelData.minutes)
                    color: modelData.key === root.nextKey
                      ? Commons.Color.accent
                      : Qt.darker(root.contentForeground, 1.2)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: modelData.key === root.nextKey
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }

          // ---- Invalid-location hint ---------------------------------
          Text {
            visible: !root.hasValidCoordinates && root.locationMode !== "auto"
            width: parent.width
            textFormat: Text.PlainText
            text: strings.t("panel.invalidCoords")
            color: Qt.darker(root.contentForeground, 1.3)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(14)
            bottomPadding: Style.space(14)
          }

          // ---- Footer / disclosure -----------------------------------
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.networkFailed ? strings.t("panel.networkFailed") : root.footerText
            color: root.networkFailed ? Commons.Color.accent : Qt.darker(root.contentForeground, 1.6)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Button {
            visible: root.networkFailed
            text: strings.t("panel.retry")
            onClicked: root.refresh()
          }
        }
      }
    }
  }
}
