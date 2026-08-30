import QtQuick
import qs.Commons
import qs.Ui

// In-panel settings (the manifest schema is documentation only in this
// Omarchy build). Every change goes through `omarecorder config set`.
Column {
  id: root
  property var svc: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property var cfg: svc ? svc.config : ({})
  readonly property var installedModels: {
    var out = []
    var ms = svc ? svc.models : []
    for (var i = 0; i < ms.length; i++) if (ms[i].installed) out.push({ value: ms[i].name, label: (ms[i].label ? ms[i].label + " · " : "") + ms[i].name })
    return out
  }

  width: parent ? parent.width : Style.space(300)
  spacing: Style.spacing.sm

  PanelSectionHeader { text: "SETTINGS"; foreground: root.foreground; fontFamily: root.fontFamily }

  Dropdown {
    width: parent.width; label: "Default model"
    value: root.cfg.defaultModel || "base.en"
    options: root.installedModels.length ? root.installedModels : [{ value: root.cfg.defaultModel || "base.en", label: root.cfg.defaultModel || "base.en" }]
    foreground: root.foreground; fontFamily: root.fontFamily
    onChanged: function(v) { if (root.svc) root.svc.setConfig("defaultModel", v) }
  }
  Dropdown {
    width: parent.width; label: "Language"
    value: root.cfg.language || "en"
    options: [{ value: "en", label: "English" }, { value: "auto", label: "Auto-detect" }]
    foreground: root.foreground; fontFamily: root.fontFamily
    onChanged: function(v) { if (root.svc) root.svc.setConfig("language", v) }
  }
  Dropdown {
    // Only offered when Obsidian has vaults on this machine; "" = the CLI picks the open vault.
    width: parent.width; label: "Obsidian vault"
    visible: root.svc && root.svc.vaults.length > 0
    value: root.cfg.obsidianVault || ""
    options: [{ value: "", label: "Automatic (the open vault)" }].concat((root.svc ? root.svc.vaults : []).map(function(v) { return { value: v.path, label: v.name + " · " + v.folder.replace(v.path + "/", "").replace(v.path, "/") } }))
    foreground: root.foreground; fontFamily: root.fontFamily
    onChanged: function(v) { if (root.svc) root.svc.setConfig("obsidianVault", v) }
  }
  Toggle {
    width: parent.width
    label: "Keep awake while recording"
    description: "Holds a systemd idle/sleep inhibitor"
    checked: root.cfg.keepAwake !== false
    foreground: root.foreground; fontFamily: root.fontFamily
    onClicked: if (root.svc) root.svc.setConfig("keepAwake", root.cfg.keepAwake === false ? "true" : "false")
  }
  Column {
    width: parent.width; spacing: Style.spacing.xxs
    Text { text: "Recordings folder"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    TextField {
      id: dirField
      width: parent.width
      text: root.cfg.recordingsDir || ""
      foreground: root.foreground
      font.family: root.fontFamily
      onAccepted: if (root.svc && text.length) root.svc.setConfig("recordingsDir", text)
    }
  }
}
