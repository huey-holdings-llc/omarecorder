import QtQuick
import qs.Commons
import qs.Ui

// Accuracy-vs-speed chooser: Fast / Balanced / Accurate as a row of chips,
// each showing the time estimate for the selected take (or the download size
// when the model is not installed), so the trade-off is visible at a glance.
// The engine model name lives in the chip tooltip.
Item {
  id: root
  property var svc: null
  property var models: svc ? svc.models : []
  property string value: svc ? svc.defaultModel : "base.en"
  property real durationS: 0
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal changed(string model)

  readonly property var current: root.findModel(value)
  readonly property bool currentInstalled: !!(current && current.installed)
  readonly property var download: svc && current ? svc.downloadFor(current.name) : null

  implicitWidth: group.implicitWidth
  implicitHeight: group.implicitHeight
  clip: true

  function findModel(name) { for (var i = 0; i < models.length; i++) if (models[i].name === name) return models[i]; return null }
  function estimateText(m) {
    if (!m || !durationS || !svc) return ""
    return "~" + svc.fmtDuration(svc.estimateSeconds(durationS, m.name))
  }
  function sizeText(m) {
    if (m.size_mb >= 1000) return (Math.round(m.size_mb / 100) / 10) + " GB ↓"
    return m.size_mb + " MB ↓"
  }
  // "Fast ~4m"  /  "Accurate 1.6 GB ↓" (not downloaded yet)
  function chipLabel(m) {
    var extra = m.installed ? estimateText(m) : sizeText(m)
    return extra ? (m.label + " " + extra) : m.label
  }
  // Chips carry the three presets; voxtype can hold more models, but the
  // catalog the picker offers is exactly the labelled ones.
  function buildOptions() {
    var opts = []
    for (var i = 0; i < models.length; i++) {
      var m = models[i]
      if (m.label) opts.push({ value: m.name, label: chipLabel(m), tooltip: m.name })
    }
    return opts
  }

  ButtonGroup {
    id: group
    options: root.buildOptions()
    value: root.value
    // The Library keyCatcher owns every key (Ctrl+M cycles the chips); the
    // group must never take Tab focus away from it.
    focusable: false
    foreground: root.foreground
    fontFamily: root.fontFamily
    onChanged: function(v) { root.value = v; root.changed(v) }
  }
}
