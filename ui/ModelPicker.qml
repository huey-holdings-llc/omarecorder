import QtQuick
import qs.Commons
import qs.Ui

// Accuracy-vs-speed chooser: Fast / Balanced / Accurate, each with its
// size (when not downloaded) or the time estimate for the selected take.
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

  // Wide enough for the longest option, no wider.
  implicitWidth: Math.ceil(metrics.width) + Style.space(52)
  implicitHeight: dropdown.implicitHeight

  TextMetrics {
    id: metrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    text: {
      var longest = ""
      var opts = root.buildOptions()
      for (var i = 0; i < opts.length; i++) if (opts[i].label.length > longest.length) longest = opts[i].label
      return longest
    }
  }

  function findModel(name) { for (var i = 0; i < models.length; i++) if (models[i].name === name) return models[i]; return null }
  function estimateText(m) {
    if (!m || !durationS || !svc) return ""
    return "≈ " + svc.fmtDuration(svc.estimateSeconds(durationS, m.name))
  }
  // "Accurate · large-v3-turbo · ≈ 52m"  /  "Balanced · small.en · 466 MB download"
  function optionLabel(m) {
    var parts = [m.label || m.name]
    if (m.label) parts.push(m.name)
    parts.push(m.installed ? estimateText(m) : m.size_mb + " MB download")
    return parts.filter(function(x) { return x }).join(" · ")
  }
  function buildOptions() {
    var presets = [], more = []
    for (var i = 0; i < models.length; i++) {
      var m = models[i]
      var o = { value: m.name, label: optionLabel(m) }
      if (m.label) presets.push(o); else more.push(o)
    }
    return presets.concat(more)
  }

  Dropdown {
    id: dropdown
    width: parent.width
    value: root.value
    options: root.buildOptions()
    foreground: root.foreground
    fontFamily: root.fontFamily
    onChanged: function(v) { root.value = v; root.changed(v) }
  }
}
