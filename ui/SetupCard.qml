import QtQuick
import qs.Commons
import qs.Ui

// Shown until `omarecorder setup check` passes. Each unmet requirement gets
// one line and, where possible, a one-click fix (model download).
Column {
  id: root
  property var svc: null
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  readonly property var setup: svc ? svc.setup : ({ ok: true })
  readonly property var dl: svc && setup && setup.defaultModel ? svc.downloadFor(setup.defaultModel) : null
  readonly property var dlModel: svc && setup && setup.defaultModel ? svc.modelByName(setup.defaultModel) : null

  visible: setup && setup.ok === false
  width: parent ? parent.width : Style.space(300)
  spacing: Style.spacing.xs

  PanelSectionHeader { text: "SETUP NEEDED"; foreground: root.urgent; fontFamily: root.fontFamily }

  Repeater {
    model: root.issues()
    delegate: Text {
      required property var modelData
      width: root.width
      text: "• " + modelData
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }
  }

  Button {
    visible: root.setup && root.setup.voxtype && root.setup.defaultModel_ok === false && !root.dl
    width: parent.width
    text: "Download " + (root.setup ? root.setup.defaultModel : "") + (root.dlModel ? " (" + root.dlModel.size_mb + " MB)" : "")
    iconText: "󰇚"
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: if (root.svc) root.svc.download(root.setup.defaultModel)
  }

  Column {
    visible: !!root.dl
    width: parent.width
    spacing: Style.spacing.xxs
    Text {
      width: parent.width
      text: "Downloading " + (root.dl ? root.dl.model : "") + "… " + (root.dl && root.dl.expected_bytes ? Math.min(99, Math.round(100 * (root.dl.bytes_done || 0) / root.dl.expected_bytes)) + "%" : "")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Rectangle {
      width: parent.width; height: Style.space(4); radius: 2
      color: Util.alpha(root.foreground, 0.15)
      Rectangle {
        height: parent.height; radius: 2
        color: Color.accent
        width: parent.width * (root.dl && root.dl.expected_bytes ? Math.min(1, (root.dl.bytes_done || 0) / root.dl.expected_bytes) : 0)
      }
    }
  }

  function issues() {
    var s = root.setup, out = []
    if (!s || s.ok !== false) return out
    if (!s.voxtype) out.push("voxtype is not installed — run: omarchy install dictation")
    if (!s.ffmpeg) out.push("ffmpeg is missing")
    if (!s.pw_record) out.push("pw-record is missing (pipewire)")
    if (!s.mic_ok) out.push("No microphone found — plug one in or pick 'system' as the source")
    if (!s.recordingsDir_ok) out.push("Cannot write to " + s.recordingsDir)
    if (s.voxtype && s.defaultModel_ok === false) out.push("Model " + s.defaultModel + " is not downloaded yet")
    return out
  }
}
