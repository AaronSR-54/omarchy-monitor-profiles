import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.monitor"
  ipcTarget: "omarchy.monitor"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0

  // Native monitor profiles: selecting one rewrites the managed block in
  // ~/.config/hypr/monitors.lua (enabling/disabling the chosen monitors) and
  // reloads Hyprland. Profiles live in ~/.config/omarchy/monitor-profiles/.
  property var profiles: []
  property string activeProfile: ""
  property var previewOutputs: []
  property bool applying: false

  // Map of monitor output -> physical name (description), from hyprctl.
  property var monitorDescriptions: ({})

  function configHome() {
    var c = Quickshell.env("XDG_CONFIG_HOME")
    return (c && c !== "") ? c : Quickshell.env("HOME") + "/.config"
  }
  readonly property string pluginDir: root.configHome() + "/omarchy/plugins/aaronsr.monitor"
  readonly property string profilesDir: root.configHome() + "/omarchy/monitor-profiles"

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale"      - 6 Button scale presets; treated as a single
  //                  horizontal row from j/k's perspective. h/l moves
  //                  between presets, identical to bluetooth's header.
  //   "profiles" - monitor profile list; j/k walks each row.
  //   "preview"    - applied-profile layout canvas; drag a monitor to reposition.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: {
    var d = displays || []
    for (var i = 0; i < d.length; i++) {
      var display = d[i]
      if (display && display.focused)
        return Model.availableScales(scalePresets, display.width, display.height)
    }
    return scalePresets
  }
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("scale")
    if ((profiles || []).length > 0) list.push("profiles")
    list.push("preview")
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "scale") return (scaleValues || []).length
    if (section === "profiles") return (profiles || []).length
    if (section === "preview") return 1
    return 0
  }

  function sectionIsSingleRow(section) {
    // brightness and text size are lone sliders; scale and profiles are
    // horizontal rows walked with h/l.
    return section === "brightness" || section === "textsize" || section === "scale"
        || section === "profiles" || section === "preview"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, or its sentinel for single-row sections.
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  // h/l: in scale and profiles rows, walks the row; everywhere else, no-op
  // because adjustBrightness handles horizontal motion on the brightness
  // slider.
  function moveCursorH(delta) {
    if (focusSection !== "scale" && focusSection !== "profiles") return
    var count = focusSection === "scale" ? scaleValues.length : profiles.length
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > count - 1) next = count - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
      return
    }
    if (focusSection === "profiles" && selectedIndex >= 0 && selectedIndex < profiles.length) {
      var p = profiles[selectedIndex]
      if (p) applyProfile(p.name)
      return
    }
    // preview: the canvas is mouse-driven (drag to reposition); nothing to apply
    // brightness: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      // brightness/text size use the -1 sentinel; scale clamps into the presets.
      if (focusSection === "brightness" || focusSection === "textsize") selectedIndex = -1
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      displays: root.displays
    })
  }

  IpcHandler {
    target: "omarchy.monitor"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
    function step() { root.step() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  // Profiles and monitor descriptions only change when a profile is applied or
  // saved, so load them at open/apply time rather than polling every few secs.
  function refreshProfiles() {
    if (!profileProc.running) profileProc.running = true
    if (!descProc.running) descProc.running = true
  }

  readonly property int activeIndex: {
    for (var i = 0; i < root.profiles.length; i++) {
      if (root.profiles[i] && root.profiles[i].active) return i
    }
    return -1
  }

  function parseStatus(raw) {
    var list = []
    try {
      var json = JSON.parse(String(raw || ""))
      if (Array.isArray(json)) list = json
    } catch (e) {}
    root.profiles = list
    root.updateActiveProfile()
    root.loadPreview()
  }

  // The active profile is the one whose enabled monitors match the monitors
  // Hyprland currently has enabled (computed from omarchy-monitor-state).
  function updateActiveProfile() {
    var enabled = []
    for (var i = 0; i < root.displays.length; i++) {
      var d = root.displays[i]
      if (d && d.enabled) enabled.push(d.name)
    }
    enabled.sort()
    var key = enabled.join(",")

    var found = ""
    for (var j = 0; j < root.profiles.length; j++) {
      var p = root.profiles[j]
      var pe = []
      if (p && p.monitors) {
        for (var k = 0; k < p.monitors.length; k++) {
          var m = p.monitors[k]
          if (m && m.enabled) pe.push(m.output)
        }
      }
      pe.sort()
      if (pe.join(",") === key) { found = p.name; break }
    }

    root.activeProfile = found
    if (root.profiles.length) {
      var rebuilt = []
      for (var j2 = 0; j2 < root.profiles.length; j2++) {
        var q = root.profiles[j2]
        rebuilt.push({ name: q.name, monitors: q.monitors, active: q.name === found })
      }
      root.profiles = rebuilt
    }
  }

  function loadPreview() {
    var name = root.activeProfile
    root.previewOutputs = []
    if (!name) return
    previewProc.command = ["cat", root.profilesDir + "/" + name + ".json"]
    if (!previewProc.running) previewProc.running = true
  }

  function parseMode(mode) {
    var dims = String(mode || "").split("@")[0].split("x")
    return {
      width: parseInt(dims[0], 10) || 0,
      height: parseInt(dims[1], 10) || 0
    }
  }

  function parsePosition(pos) {
    var p = String(pos || "").split("x")
    return {
      x: parseInt(p[0], 10) || 0,
      y: parseInt(p[1], 10) || 0
    }
  }

  function parsePreview(raw) {
    try {
      var json = JSON.parse(String(raw || ""))
      root.previewOutputs = (json.monitors || []).map(function(m) {
        var dims = root.parseMode(m.mode)
        var pos = root.parsePosition(m.position)
        return {
          name: m.output || "",
          enabled: !!m.enabled,
          mode: m.mode || "",
          position: m.position || "",
          scale: Number(m.scale) || 1,
          width: dims.width,
          height: dims.height,
          x: pos.x,
          y: pos.y
        }
      })
    } catch (e) {
      root.previewOutputs = []
    }
  }

  function parseDescriptions(raw) {
    var map = {}
    try {
      var arr = JSON.parse(String(raw || ""))
      for (var i = 0; i < (arr || []).length; i++) {
        var m = arr[i]
        if (!m || !m.name) continue
        // Short name: make + model, no serial.
        var parts = []
        if (m.make) parts.push(m.make)
        if (m.model) parts.push(m.model)
        map[m.name] = parts.join(" ")
      }
    } catch (e) {}
    root.monitorDescriptions = map
  }

  function displayName(output) {
    var desc = root.monitorDescriptions[output]
    if (desc && desc !== output) return output + " (" + desc + ")"
    return output
  }

  // Logical layout of the active profile's enabled monitors for the
  // repositioning canvas: { name, x, y, w, h, mode, position } in unscaled px.
  function previewLayout() {
    var out = []
    var mons = root.previewOutputs || []
    for (var i = 0; i < mons.length; i++) {
      var m = mons[i]
      if (!m || !m.enabled) continue
      var s = Number(m.scale) || 1
      out.push({
        name: m.name,
        display: root.displayName(m.name),
        x: m.x,
        y: m.y,
        w: (m.width || 0) / s,
        h: (m.height || 0) / s,
        mode: m.mode || "",
        position: m.position || ""
      })
    }
    return out
  }

  function setMonitorPosition(output, x, y) {
    if (!output) return
    posProc.command = ["bash", root.pluginDir + "/set-position.sh", output, String(Math.round(x)), String(Math.round(y))]
    if (!posProc.running) posProc.running = true
  }

  // Save pending drag positions (one set-position.sh call per moved monitor)
  // and re-apply the active profile once. Does nothing if nothing moved.
  function savePendingPositions(pending) {
    if (!pending || pending.length === 0 || root.applying) return
    root.applying = true
    saveProc.command = ["bash", root.pluginDir + "/apply-profile.sh", root.activeProfile, "--positions", JSON.stringify(pending)]
    saveProc.running = true
  }

  function applyProfile(name) {
    if (!name || root.applying) return
    root.applying = true
    root.close()
    applyProc.command = ["bash", root.pluginDir + "/apply-profile.sh", name]
    applyProc.running = true
  }

  // Keybind path (SUPER+SHIFT+P): open the selector focused on the active
  // profile, then each further press advances the cursor to the next profile.
  // Nothing is applied until Enter.
  function step() {
    if (!root.opened) {
      root.open()
      root.cursorActive = true
      root.focusSection = "profiles"
      root.selectedIndex = root.activeIndex >= 0 ? root.activeIndex : 0
      return
    }
    if (root.profiles.length === 0) return
    root.cursorActive = true
    root.focusSection = "profiles"
    root.selectedIndex = (root.selectedIndex + 1) % root.profiles.length
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.matchingScaleIndex(scaleValues, monitorScale, display.width, display.height)
    }
    return -1
  }

  function effectiveScale(scale) {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.cleanScale(scale, display.width, display.height)
    }
    return normalizeScale(scale)
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function setScale(scale) {
    if (!root.focusedMonitor) return
    actionProc.command = ["bash", root.pluginDir + "/set-scale.sh", root.focusedMonitor, scale]
    if (!actionProc.running) actionProc.running = true
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    refresh()
    refreshProfiles()
  }

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      refreshProfiles()
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    }
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onProfilesChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
        root.updateActiveProfile()
        if (root.activeProfile) root.loadPreview()
      }
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) {
      root.refresh()
      root.refreshProfiles()
    }
  }

  Process {
    id: profileProc
    command: ["bash", root.pluginDir + "/list-profiles.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseStatus(text)
    }
  }

  Process {
    id: applyProc
    command: ["true"]
    onRunningChanged: function() {
      if (!running) {
        root.applying = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: previewProc
    command: ["true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parsePreview(text)
    }
  }

  // Physical monitor names (descriptions) for the layout tiles.
  Process {
    id: descProc
    command: ["hyprctl", "monitors", "all", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseDescriptions(text)
    }
  }

  Process {
    id: posProc
    command: ["true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.refresh()
    }
  }

  Process {
    id: saveProc
    command: ["true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() {
        root.applying = false
        Qt.callLater(function() {
          root.refresh()
          root.refreshProfiles()
        })
      }
    }
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(960))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale" || root.focusSection === "profiles") root.moveCursorH(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Display"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                text: {
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return "FIXED BRIGHTNESS"
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.brightnessAvailable
            foreground: root.bar.foreground
          }

          Column {
            visible: root.brightnessAvailable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: "BRIGHTNESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
                text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                value: root.brightnessPercent
                integer: true
                onMoved: function(v) { root.previewBrightness(v) }
                onReleased: function(v) {
                  brightnessDebounce.stop()
                  root.setBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Text size ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: "TEXT SIZE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                text: (textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Scale ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: "SCALE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Name the monitor SCALE targets, since it only applies to the
              // focused one.
              Text {
                id: scaleMonitor
                text: root.focusedMonitor
                // Only worth naming when more than one display is in play.
                visible: root.focusedMonitor !== "" && root.enabledDisplayCount > 1
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: scaleRow
              width: parent.width
              columns: root.scaleValues.length
              spacing: Style.spacing.xs

              readonly property real cellWidth: root.scaleValues.length > 0
                ? (width - spacing * (columns - 1)) / columns
                : 0

              Repeater {
                model: root.scaleValues

                ScalePill {
                  required property string modelData
                  required property int index

                  scaleValue: modelData
                  scaleIndex: index
                  width: scaleRow.cellWidth
                }
              }
            }
          }

          // ---------- Monitor profiles ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "MONITOR PROFILES"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Grid {
              id: profileRow
              width: parent.width
              columns: root.profiles.length > 0 ? root.profiles.length : 1
              spacing: Style.spacing.xs

              readonly property real cellWidth: root.profiles.length > 0
                ? (width - spacing * (columns - 1)) / columns
                : 0

              Repeater {
                model: root.profiles

                ProfilePill {
                  required property var modelData
                  required property int index

                  width: profileRow.cellWidth
                  profile: modelData
                  profileIndex: index
                }
              }
            }

            // ---------- Applied-profile preview ----------
            ProfilePreview {
              width: parent.width
              hasCursor: root.cursorActive && root.focusSection === "preview" && root.selectedIndex === 0
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component ScalePill: Button {
    id: pill
    required property string scaleValue
    required property int scaleIndex

    text: root.effectiveScale(scaleValue) + "x"
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.activeScaleIndex() === scaleIndex
    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === scaleIndex

    onClicked: root.setScale(scaleValue)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "scale"
      root.selectedIndex = pill.scaleIndex
    }
  }

  component ProfilePreview: Item {
    id: preview
    required property bool hasCursor

    readonly property var layoutMonitors: root.previewLayout()
    property var pending: []

    implicitHeight: previewContent.implicitHeight

    Column {
      id: previewContent
      width: parent.width
      spacing: Style.space(8)

      LayoutView {
        id: layoutView
        width: parent.width
        monitors: preview.layoutMonitors
        onPositionsChanged: function(pending) {
          preview.pending = pending
        }
      }

      // Helper / pending-change controls. Shows the drag hint, or the
      // unsaved-changes label + actions once the user starts repositioning.
      // Fixed height + single-line text so nothing jumps when the buttons
      // appear/disappear.
      Row {
        id: controlsRow
        width: parent.width
        height: Math.max(saveButton.implicitHeight, discardButton.implicitHeight)
        spacing: Style.space(8)
        visible: preview.pending.length > 0 || preview.layoutMonitors.length > 1

        Text {
          id: helperText
          text: preview.pending.length > 0 ? "Unsaved changes" : "Drag a monitor to reposition it"
          color: preview.pending.length > 0 ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
          maximumLineCount: 1
          elide: Text.ElideRight
          width: preview.pending.length > 0
                 ? (parent.width - saveButton.implicitWidth - discardButton.implicitWidth - parent.spacing * 2)
                 : parent.width
        }

        Button {
          id: discardButton
          text: "DISCARD"
          visible: preview.pending.length > 0
          fontSize: Style.font.caption
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.sm
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          onClicked: layoutView.resetDraft()
        }

        Button {
          id: saveButton
          text: "SAVE"
          visible: preview.pending.length > 0
          fontSize: Style.font.caption
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.sm
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          active: true
          onClicked: {
            root.savePendingPositions(preview.pending)
            layoutView.resetDraft()
          }
        }
      }

      Text {
        visible: preview.layoutMonitors.length === 0
        text: root.activeProfile ? "No monitors in profile" : "No profile applied"
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        width: parent.width
      }
    }
  }

  // Interactive layout view: draws the active profile's enabled monitors at
  // their relative logical positions; drag a monitor to reposition it. Dragging
  // only updates the in-memory draft — nothing is applied until the caller
  // saves (see ProfilePreview).
  component LayoutView: Item {
    id: canvas
    required property var monitors
    signal positionsChanged(var pending)

    // Editable working copy of the monitors.
    property var draft: []
    // Positions that changed since the draft was last reset (or saved).
    property var pending: []

    implicitHeight: Style.space(240)
    readonly property bool draggable: (draft || []).length > 1
    readonly property real pad: Style.space(10)
    property real fitScale: 1
    property real offsetX: 0
    property real offsetY: 0

    function cloneMonitors(mons) {
      var out = []
      for (var i = 0; i < (mons || []).length; i++) {
        var m = mons[i]
        out.push({ name: m.name, display: m.display || m.name, x: m.x, y: m.y, w: m.w, h: m.h, mode: m.mode || "", position: m.position || "" })
      }
      return out
    }

    function resetDraft() {
      canvas.draft = canvas.cloneMonitors(canvas.monitors)
      canvas.pending = []
      canvas.positionsChanged([])
    }

    // Repopulate the draft from the source monitors, but never clobber
    // unsaved drags: a periodic refresh re-reads the profile and would
    // otherwise wipe the user's in-progress repositioning.
    function reloadIfClean() {
      if ((canvas.pending || []).length === 0) {
        canvas.draft = canvas.cloneMonitors(canvas.monitors)
      }
    }

    // Snap the dragged monitor so it cannot overlap others and lands glued to
    // the nearest one. Returns the corrected {x, y}.
    function snapMonitor(drag) {
      var mons = canvas.draft || []
      var others = []
      for (var i = 0; i < mons.length; i++) {
        if (mons[i].name !== drag.name) others.push(mons[i])
      }
      if (others.length === 0) return { x: drag.x, y: drag.y }

      // Find the nearest other monitor by the minimum edge gap.
      var best = null
      var bestGap = 1e18
      var bestSide = ""
      for (var j = 0; j < others.length; j++) {
        var o = others[j]
        // horizontal gap (0 if they overlap in x)
        var gapX = Math.max(o.x - (drag.x + drag.w), drag.x - (o.x + o.w), 0)
        // vertical gap (0 if they overlap in y)
        var gapY = Math.max(o.y - (drag.y + drag.h), drag.y - (o.y + o.h), 0)
        // gap = distance between the rectangles (0 if they touch/overlap)
        var g = Math.sqrt(gapX * gapX + gapY * gapY)
        if (g < bestGap) {
          bestGap = g
          best = o
        }
      }
      if (!best) return { x: drag.x, y: drag.y }

      // Which side of `best` to attach to: pick the closest gap axis.
      var rGap = drag.x - (best.x + best.w)      // drag is to the right
      var lGap = best.x - (drag.x + drag.w)      // drag is to the left
      var dGap = drag.y - (best.y + best.h)      // drag is below
      var uGap = best.y - (drag.y + drag.h)      // drag is above

      // Signed values > 0 mean a real gap on that side; negative means overlap.
      var sides = [
        { gap: rGap, side: "right" },
        { gap: lGap, side: "left" },
        { gap: dGap, side: "down" },
        { gap: uGap, side: "up" }
      ]
      var chosen = sides[0]
      for (var k = 1; k < sides.length; k++) {
        if (sides[k].gap > chosen.gap) chosen = sides[k]
      }

      // Glue the dragged monitor against that side of `best`, keeping its own
      // offset along the perpendicular axis (no forced centering).
      var nx = drag.x
      var ny = drag.y
      if (chosen.side === "right") {
        nx = best.x + best.w
      } else if (chosen.side === "left") {
        nx = best.x - drag.w
      } else if (chosen.side === "down") {
        ny = best.y + best.h
      } else { // up
        ny = best.y - drag.h
      }

      return { x: Math.round(nx), y: Math.round(ny) }
    }

    function recordDrop(name, absX, absY) {
      var idx = -1
      for (var i = 0; i < canvas.draft.length; i++) {
        if (canvas.draft[i].name === name) { idx = i; break }
      }
      if (idx < 0) return

      // Build a temporary drag object, snap it against the others, then commit.
      var drag = canvas.draft[idx]
      var snapped = canvas.snapMonitor({ name: drag.name, x: absX, y: absY, w: drag.w, h: drag.h })
      var fx = snapped.x
      var fy = snapped.y

      var updated = canvas.draft[idx]
      updated.x = fx
      updated.y = fy
      updated.position = fx + "x" + fy
      var fresh = canvas.draft.slice()
      fresh[idx] = updated
      canvas.draft = fresh

      var pend = canvas.pending.slice()
      var found = false
      for (var j = 0; j < pend.length; j++) {
        if (pend[j].output === name) {
          pend[j].x = fx; pend[j].y = fy; found = true; break
        }
      }
      if (!found) pend.push({ output: name, x: fx, y: fy })
      canvas.pending = pend
      canvas.positionsChanged(pend)
    }

    onMonitorsChanged: reloadIfClean()

    function computeFit() {
      var mons = canvas.draft || []
      if (!mons.length || canvas.width <= 0) return
      var minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9
      for (var i = 0; i < mons.length; i++) {
        var m = mons[i]
        if (m.x < minX) minX = m.x
        if (m.y < minY) minY = m.y
        if (m.x + m.w > maxX) maxX = m.x + m.w
        if (m.y + m.h > maxY) maxY = m.y + m.h
      }
      var bw = maxX - minX
      var bh = maxY - minY
      if (bw <= 0 || bh <= 0) return
      var s = Math.min((canvas.width - canvas.pad * 2) / bw, (canvas.implicitHeight - canvas.pad * 2) / bh)
      if (!isFinite(s) || s <= 0) return
      canvas.fitScale = s

      // Center the layout content in the canvas both horizontally and
      // vertically, regardless of the monitors' absolute coordinates.
      var contentW = bw * s
      var contentH = bh * s
      var left = Math.max(minX, 0)
      var top = Math.max(minY, 0)
      canvas.offsetX = canvas.pad + (canvas.width - canvas.pad * 2 - contentW) / 2 - left * s
      canvas.offsetY = canvas.pad + (canvas.implicitHeight - canvas.pad * 2 - contentH) / 2 - top * s
    }

    onDraftChanged: {
      computeFit()
      if (monitorHost) monitorHost.rebuild()
    }
    onWidthChanged: computeFit()

    // Single dark container: the layout background AND the parent the monitor
    // rectangles are created into. A subtle grid reinforces that the area is
    // draggable.
    Rectangle {
      id: layer
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Color.menu.background
      border.width: 1
      border.color: Color.menu.border
      clip: true

      // Background grid, drawn once (it is a fixed child of the layer).
      Canvas {
        id: gridLayer
        z: 0
        anchors.fill: parent
        visible: canvas.draggable

        readonly property real grid: 18

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var w = gridLayer.width
          var h = gridLayer.height
          var g = gridLayer.grid
          ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.04)
          ctx.lineWidth = 1
          ctx.beginPath()
          for (var x = 0; x <= w; x += g) {
            ctx.moveTo(x + 0.5, 0)
            ctx.lineTo(x + 0.5, h)
          }
          for (var y = 0; y <= h; y += g) {
            ctx.moveTo(0, y + 0.5)
            ctx.lineTo(w, y + 0.5)
          }
          ctx.stroke()
        }

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onVisibleChanged: requestPaint()
      }

      // Monitors live in their own host so rebuild() only touches them and
      // never the grid or the layer itself. Keep it above the grid.
      Item {
        id: monitorHost
        z: 1
        anchors.fill: parent

        function rebuild() {
          var toDestroy = []
          for (var i = 0; i < monitorHost.children.length; i++) toDestroy.push(monitorHost.children[i])
          for (var j = 0; j < toDestroy.length; j++) toDestroy[j].destroy()

          var mons = canvas.draft || []
          for (var k = 0; k < mons.length; k++) {
            var m = mons[k]
            var obj = monitorComponent.createObject(monitorHost, { mIndex: k })
            obj.monitorName = m.name
          }
        }
      }
    }

    Component {
      id: monitorComponent
      Rectangle {
        property int mIndex: -1
        property string monitorName: ""

        readonly property var layout: canvas
        readonly property var modelData: (canvas.draft && mIndex >= 0 && mIndex < canvas.draft.length) ? canvas.draft[mIndex] : null

        x: modelData ? modelData.x * layout.fitScale + layout.offsetX : 0
        y: modelData ? modelData.y * layout.fitScale + layout.offsetY : 0
        width: modelData ? Math.max(24, modelData.w * layout.fitScale) : 24
        height: modelData ? Math.max(14, modelData.h * layout.fitScale) : 14
        radius: Style.cornerRadius
        color: Util.alpha(Style.selectedStateColor(root.bar.foreground, Color.accent), 0.9)
        border.width: 1
        border.color: Color.menu.selectedBorder

        // "2560x1440 · 120Hz" and, one line below, "1979x-100"
        readonly property string specText: {
          var parts = []
          var dims = String(modelData ? modelData.mode : "").split("@")[0]
          if (dims) parts.push(dims)
          var m = String(modelData ? modelData.mode : "").split("@")[1] || ""
          if (m) parts.push(parseInt(m, 10) + "Hz")
          return parts.join(" · ")
        }
        readonly property string positionText: modelData && modelData.position ? modelData.position : ""
        readonly property string displayText: modelData && modelData.display ? modelData.display : (modelData ? modelData.name : "")

        Column {
          anchors.centerIn: parent
          width: parent.width - Style.space(4)
          spacing: 1

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: parent.parent.displayText
            color: Color.background
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideMiddle
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: parent.parent.specText
            visible: parent.parent.width >= Style.space(46)
            color: Color.background
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            opacity: 0.7
            elide: Text.ElideMiddle
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: parent.parent.positionText
            visible: parent.parent.width >= Style.space(46) && parent.parent.positionText !== ""
            color: Color.background
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            opacity: 0.7
            elide: Text.ElideMiddle
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: parent.layout.draggable
          hoverEnabled: parent.layout.draggable
          cursorShape: parent.layout.draggable ? Qt.SizeAllCursor : Qt.ArrowCursor
          drag.target: parent
          drag.threshold: 2
          onReleased: function() {
            if (!parent.layout.draggable) return
            var absX = Math.round((parent.x - parent.layout.offsetX) / parent.layout.fitScale)
            var absY = Math.round((parent.y - parent.layout.offsetY) / parent.layout.fitScale)
            if (absX === parent.modelData.x && absY === parent.modelData.y) return
            parent.layout.recordDrop(parent.monitorName, absX, absY)
          }
        }
      }
    }

  }

  component ProfilePill: Button {
    id: pill
    required property var profile
    required property int profileIndex

    text: profile.name
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: !!profile.active
    hasCursor: root.cursorActive && root.focusSection === "profiles" && root.selectedIndex === profileIndex

    onClicked: root.applyProfile(profile.name)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "profiles"
      root.selectedIndex = pill.profileIndex
    }
  }
}
