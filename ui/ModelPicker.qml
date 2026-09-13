import QtQuick
import qs.Commons
import qs.Ui
import "state.js" as State

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
  function fullLabel(m) {
    var extra = m.installed ? estimateText(m) : sizeText(m)
    return extra ? (m.label + " " + extra) : m.label
  }
  // When the row cannot fit the full labels the chips drop their estimates
  // (name only, estimate in the tooltip) instead of getting clipped. The
  // container flips this by comparing its available width to fullWidth.
  property bool compact: false
  TextMetrics {
    id: fullMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    text: {
      var t = ""
      for (var i = 0; i < root.models.length; i++) if (root.models[i].label) t += root.fullLabel(root.models[i])
      return t
    }
  }
  // Full-label width estimate: text + per-chip padding and borders + gaps.
  // Deliberately independent of `compact`, so the comparison cannot loop.
  readonly property real fullWidth: Math.ceil(fullMetrics.width)
    + 6 * Style.spacing.controlPaddingX + 2 * Style.spacing.md + 6 + Style.spacing.sm
  // The same for the names alone: the least the chips need. The Library gives
  // up its button's label before letting the chips clip below this.
  TextMetrics {
    id: compactMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    text: {
      var t = ""
      for (var i = 0; i < root.models.length; i++) if (root.models[i].label) t += root.models[i].label
      return t
    }
  }
  readonly property real compactWidth: Math.ceil(compactMetrics.width)
    + 6 * Style.spacing.controlPaddingX + 2 * Style.spacing.md + 6 + Style.spacing.sm
  // Chips carry the three presets; voxtype can hold more models, but the
  // catalog the picker offers is exactly the labelled ones.
  function buildOptions() {
    var opts = []
    for (var i = 0; i < models.length; i++) {
      var m = models[i]
      if (!m.label) continue
      var extra = m.installed ? estimateText(m) : sizeText(m)
      // Fast and Balanced are whisper's .en models; say so where the name is.
      var name = m.name + (State.englishOnly(m.name) ? " · English only" : "")
      if (compact) opts.push({ value: m.name, label: m.label, tooltip: name + (extra ? " · " + extra : "") })
      else opts.push({ value: m.name, label: fullLabel(m), tooltip: name })
    }
    return opts
  }

  // The chips clip (a row too narrow for them cuts them rather than letting
  // them spill); the picker itself does not, so a key badge can sit on its
  // corner like every other control's.
  Item {
    anchors.fill: parent
    clip: true
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
}
