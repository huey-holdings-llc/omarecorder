import QtQuick
import qs.Commons
import qs.Ui

// Accuracy-vs-speed chooser. Presets (Fast/Balanced/Accurate) first, then
// the rest of voxtype's whisper models under "More". Shows size + estimate.
Item {
  id: root
  property var svc: null
  property var models: svc ? svc.models : []
  property string value: svc ? svc.defaultModel : "base.en"
  property real durationS: 0
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool hasCursor: false

  signal changed(string model)

  readonly property var current: root.findModel(value)
  readonly property bool currentInstalled: !!(current && current.installed)
  readonly property var download: svc && current ? svc.downloadFor(current.name) : null

  implicitWidth: parent ? parent.width : Style.space(300)
  implicitHeight: dropdown.implicitHeight

  function findModel(name) { for (var i = 0; i < models.length; i++) if (models[i].name === name) return models[i]; return null }
  function estimateText(m) {
    if (!m || !durationS) return ""
    var s = Math.ceil(durationS / (m.rtf || 3))
    return "≈ " + (svc ? svc.fmtDuration(s) : s + "s") + (m.rtf_source === "measured" ? "" : " (est.)")
  }
  function optionLabel(m) {
    var head = m.label ? m.label + " · " + m.name : m.name
    var tail = m.installed ? estimateText(m) : "download " + m.size_mb + " MB"
    return head + (tail ? "  —  " + tail : "")
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
    label: "Model"
    value: root.value
    options: root.buildOptions()
    foreground: root.foreground
    fontFamily: root.fontFamily
    hasCursor: root.hasCursor
    onChanged: function(v) { root.value = v; root.changed(v) }
  }
}
