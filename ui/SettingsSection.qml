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
  // The popup's key catcher must stand down while a settings field is edited.
  readonly property bool editing: dirField.activeFocus || dictHeard.activeFocus || dictWritten.activeFocus
  property bool dictAddOpen: false
  property string dictStatus: ""
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
  Toggle {
    width: parent.width
    label: "Transcribe when a recording stops"
    description: "Starts the default model automatically when it is installed"
    checked: root.cfg.autoTranscribe === true
    foreground: root.foreground; fontFamily: root.fontFamily
    onClicked: if (root.svc) root.svc.setConfig("autoTranscribe", root.cfg.autoTranscribe === true ? "false" : "true")
  }
  Column {
    width: parent.width; spacing: Style.spacing.xxs
    Text {
      text: "Dictionary (" + ((root.svc && root.svc.dictionary) ? root.svc.dictionary.count : 0) + " entries) · fixes whisper mishearings in tidy transcripts"
      color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption
    }
    Row {
      width: parent.width; spacing: Style.spacing.sm
      Button {
        width: (parent.width - parent.spacing * 3) / 4; text: "Edit"
        fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
        foreground: root.foreground; fontFamily: root.fontFamily
        onClicked: { if (root.svc) root.svc.dictEdit(); root.dictStatus = "opened in your editor" ; dictStatusClear.restart() }
      }
      Button {
        width: (parent.width - parent.spacing * 3) / 4; text: "Add"
        active: root.dictAddOpen
        fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
        foreground: root.foreground; fontFamily: root.fontFamily
        onClicked: { root.dictAddOpen = !root.dictAddOpen; if (root.dictAddOpen) dictHeard.forceActiveFocus() }
      }
      Button {
        width: (parent.width - parent.spacing * 3) / 4; text: "Copy prompt"
        fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
        foreground: root.foreground; fontFamily: root.fontFamily
        onClicked: if (root.svc) root.svc.dictCopyPrompt(function(code) { root.dictStatus = code === 0 ? "prompt copied; paste it into your LLM" : ""; dictStatusClear.restart() })
      }
      Button {
        width: (parent.width - parent.spacing * 3) / 4; text: "Paste entries"
        fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
        foreground: root.foreground; fontFamily: root.fontFamily
        onClicked: if (root.svc) root.svc.dictImportClipboard(function(code, out) { root.dictStatus = code === 0 ? String(out).trim() : ""; dictStatusClear.restart() })
      }
    }
    Row {
      visible: root.dictAddOpen
      width: parent.width; spacing: Style.spacing.sm
      TextField {
        id: dictHeard
        width: (parent.width - parent.spacing) / 2
        placeholderText: "what whisper wrote"
        foreground: root.foreground; font.family: root.fontFamily
        onAccepted: dictWritten.forceActiveFocus()
        Keys.onEscapePressed: { root.dictAddOpen = false; focus = false }
      }
      TextField {
        id: dictWritten
        width: (parent.width - parent.spacing) / 2
        placeholderText: "what you meant · Enter adds"
        foreground: root.foreground; font.family: root.fontFamily
        onAccepted: {
          if (dictHeard.text.trim().length && text.trim().length && root.svc) {
            root.svc.dictAdd(dictHeard.text.trim(), text.trim(), function(code, out) {
              root.dictStatus = code === 0 ? String(out).trim() : (root.svc.lastError || "not added")
              dictStatusClear.restart()
            })
            dictHeard.text = ""; text = ""; root.dictAddOpen = false; focus = false
          }
        }
        Keys.onEscapePressed: { root.dictAddOpen = false; focus = false }
      }
    }
    Text {
      visible: root.dictStatus.length > 0
      width: parent.width; wrapMode: Text.Wrap
      text: root.dictStatus
      color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption
    }
    Timer { id: dictStatusClear; interval: 6000; onTriggered: root.dictStatus = "" }
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
      onAccepted: { if (root.svc && text.length) root.svc.setConfig("recordingsDir", text); focus = false }
      Keys.onEscapePressed: { text = root.cfg.recordingsDir || ""; focus = false }
    }
  }
}
