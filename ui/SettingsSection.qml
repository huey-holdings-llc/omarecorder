import QtQuick
import qs.Commons
import qs.Ui

// In-panel settings (the manifest schema is documentation only in this
// Omarchy build). Every change goes through `omarecorder config set`.
// Order: the folder and vault people actually revisit sit above the
// set-and-forget toggles; the dictionary card closes the section.
Item {
  id: root
  property var svc: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property var cfg: svc ? svc.config : ({})
  // The popup's key catcher must stand down while a settings field is edited.
  readonly property bool editing: dirField.activeFocus || dictHeard.activeFocus || dictWritten.activeFocus
    || modelDrop.popupOpen || langDrop.popupOpen || vaultDrop.popupOpen
  property bool dictAddOpen: false
  property string dictStatus: ""
  // The popup's `d` key lands here: settings open, Add row expanded, cursor
  // in the heard field.
  function focusDictAdd() { dictAddOpen = true; dictHeard.forceActiveFocus() }

  // Keyboard reach: with settings open, the popup's j/k cursor walks these
  // controls in the order they sit, and Enter or Space works the one under it.
  property bool cursorActive: false
  property int cursorIndex: -1
  signal cursorMoved(Item item)
  // A field or dropdown gave the keyboard back; the popup has to take it again.
  signal doneEditing()
  readonly property var cursorItems: [modelDrop, langDrop, dirField].concat(vaultDrop.visible ? [vaultDrop] : [])
    .concat([keepAwake, autoTx, enhance, dictEditButton, dictAddButton, dictPromptButton, dictPasteButton])
  function cursorOn(item) { return cursorActive && cursorItems[cursorIndex] === item }
  function resetCursor() { cursorActive = false; cursorIndex = -1; cursorMark.visible = false }
  function moveCursor(dy) {
    cursorActive = true
    cursorIndex = Math.max(0, Math.min(cursorItems.length - 1, cursorIndex + dy))
    cursorMoved(cursorItems[cursorIndex])
    Qt.callLater(placeMark)
  }
  function activateCursor() {
    if (!cursorActive || cursorIndex < 0 || cursorIndex >= cursorItems.length) return
    var item = cursorItems[cursorIndex]
    if (item === dirField) { dirField.forceActiveFocus(); dirField.selectAll() }
    else if (item === modelDrop || item === langDrop || item === vaultDrop) item.open()
    else item.clicked()
  }
  readonly property var installedModels: {
    var out = []
    var ms = svc ? svc.models : []
    for (var i = 0; i < ms.length; i++) if (ms[i].installed) out.push({ value: ms[i].name, label: (ms[i].label ? ms[i].label + " · " : "") + ms[i].name })
    return out
  }

  width: parent ? parent.width : Style.space(300)
  height: col.implicitHeight

  // The kit's own cursor state (hasCursor) is a faint border change in the
  // default themes, fainter than a control at rest, so the keyboard cursor
  // also gets an accent bar in a narrow gutter beside the control it is on.
  readonly property int cursorGutter: Style.space(8)
  function placeMark() {
    var t = cursorActive && cursorIndex >= 0 && cursorIndex < cursorItems.length ? cursorItems[cursorIndex] : null
    if (!t || !t.visible) { cursorMark.visible = false; return }
    cursorMark.y = t.mapToItem(root, 0, 0).y
    cursorMark.height = t.height
    cursorMark.visible = true
  }
  onHeightChanged: Qt.callLater(placeMark)
  Rectangle {
    id: cursorMark
    visible: false
    x: Style.space(2)
    width: Style.space(3)
    radius: width / 2
    color: Color.accent
  }

  Column {
    id: col
    x: root.cursorGutter
    width: parent.width - root.cursorGutter
    spacing: Style.spacing.sm

    PanelSectionHeader { text: "SETTINGS"; foreground: root.foreground; fontFamily: root.fontFamily }

    Dropdown {
      id: modelDrop
      hasCursor: root.cursorOn(modelDrop)
      onPopupOpenChanged: if (!popupOpen) root.doneEditing()
      width: parent.width; label: "Default model"
      value: root.cfg.defaultModel || "base.en"
      options: root.installedModels.length ? root.installedModels : [{ value: root.cfg.defaultModel || "base.en", label: root.cfg.defaultModel || "base.en" }]
      foreground: root.foreground; fontFamily: root.fontFamily
      onChanged: function(v) { if (root.svc) root.svc.setConfig("defaultModel", v) }
    }
    Dropdown {
      id: langDrop
      hasCursor: root.cursorOn(langDrop)
      onPopupOpenChanged: if (!popupOpen) root.doneEditing()
      width: parent.width; label: "Language"
      value: root.cfg.language || "en"
      options: [{ value: "en", label: "English" }, { value: "auto", label: "Auto-detect" }]
      foreground: root.foreground; fontFamily: root.fontFamily
      onChanged: function(v) { if (root.svc) root.svc.setConfig("language", v) }
    }
    Column {
      width: parent.width; spacing: Style.spacing.xxs
      Text { text: "Recordings folder"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption }
      TextField {
        id: dirField
        hasCursor: root.cursorOn(dirField)
        width: parent.width
        text: root.cfg.recordingsDir || ""
        foreground: root.foreground
        font.family: root.fontFamily
        onAccepted: { if (root.svc && text.length) root.svc.setConfig("recordingsDir", text); focus = false; root.doneEditing() }
        Keys.onEscapePressed: { text = Qt.binding(function() { return root.cfg.recordingsDir || "" }); focus = false; root.doneEditing() }
      }
    }
    Dropdown {
      // Only offered when Obsidian has vaults on this machine; "" = the CLI picks the open vault.
      id: vaultDrop
      hasCursor: root.cursorOn(vaultDrop)
      onPopupOpenChanged: if (!popupOpen) root.doneEditing()
      width: parent.width; label: "Obsidian vault"
      visible: root.svc && root.svc.vaults.length > 0
      value: root.cfg.obsidianVault || ""
      options: [{ value: "", label: "Automatic (the open vault)" }].concat((root.svc ? root.svc.vaults : []).map(function(v) { return { value: v.path, label: v.name + " · " + v.folder.replace(v.path + "/", "").replace(v.path, "/") } }))
      foreground: root.foreground; fontFamily: root.fontFamily
      onChanged: function(v) { if (root.svc) root.svc.setConfig("obsidianVault", v) }
    }
    Toggle {
      width: parent.width
      id: keepAwake
      hasCursor: root.cursorOn(keepAwake)
      label: "Keep awake while recording"
      description: "Holds a systemd idle/sleep inhibitor"
      checked: root.cfg.keepAwake !== false
      foreground: root.foreground; fontFamily: root.fontFamily
      onClicked: if (root.svc) root.svc.setConfig("keepAwake", root.cfg.keepAwake === false ? "true" : "false")
    }
    Toggle {
      width: parent.width
      id: autoTx
      hasCursor: root.cursorOn(autoTx)
      label: "Transcribe when a recording stops"
      description: "Starts the default model automatically when it is installed"
      checked: root.cfg.autoTranscribe === true
      foreground: root.foreground; fontFamily: root.fontFamily
      onClicked: if (root.svc) root.svc.setConfig("autoTranscribe", root.cfg.autoTranscribe === true ? "false" : "true")
    }
    Toggle {
      width: parent.width
      id: enhance
      hasCursor: root.cursorOn(enhance)
      label: "Clean up audio before transcribing"
      description: "Noise and level cleanup on a temporary copy; the recording itself is never altered"
      checked: root.cfg.enhanceAudio === true
      foreground: root.foreground; fontFamily: root.fontFamily
      onClicked: if (root.svc) root.svc.setConfig("enhanceAudio", root.cfg.enhanceAudio === true ? "false" : "true")
    }

    BorderSurface {
      width: parent.width
      height: dictInner.implicitHeight + Style.spacing.sm * 2
      radius: Style.cornerRadius
      color: "transparent"
      borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

      Column {
        id: dictInner
        anchors.fill: parent
        anchors.margins: Style.spacing.sm
        spacing: Style.spacing.xxs
        Text {
          width: parent.width
          // Wraps rather than clipping at the card edge on narrow panels.
          wrapMode: Text.Wrap
          text: "Dictionary (" + ((root.svc && root.svc.dictionary) ? root.svc.dictionary.count : 0) + " entries) · fixes words the transcriber keeps getting wrong"
          color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption
        }
        Row {
          width: parent.width; spacing: Style.spacing.sm
          Button {
            id: dictEditButton; hasCursor: root.cursorOn(dictEditButton)
            width: (parent.width - parent.spacing * 3) / 4; text: "Edit"
            tooltipText: "Open the dictionary file in your editor"
            fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
            foreground: root.foreground; fontFamily: root.fontFamily
            onClicked: { if (root.svc) root.svc.dictEdit(); root.dictStatus = "opened in your editor" ; dictStatusClear.restart() }
          }
          Button {
            id: dictAddButton; hasCursor: root.cursorOn(dictAddButton)
            width: (parent.width - parent.spacing * 3) / 4; text: "Add (d)"
            active: root.dictAddOpen
            tooltipText: "Add one correction: what was heard, what you meant"
            fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
            foreground: root.foreground; fontFamily: root.fontFamily
            onClicked: { root.dictAddOpen = !root.dictAddOpen; if (root.dictAddOpen) dictHeard.forceActiveFocus() }
          }
          Button {
            id: dictPromptButton; hasCursor: root.cursorOn(dictPromptButton)
            width: (parent.width - parent.spacing * 3) / 4; text: "Copy prompt"
            tooltipText: "Copy a ready-made request to the clipboard; ask your LLM, then Paste entries"
            fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
            foreground: root.foreground; fontFamily: root.fontFamily
            onClicked: if (root.svc) root.svc.dictCopyPrompt(function(code) { root.dictStatus = code === 0 ? "prompt copied · fill in the \"I talk about\" line, then paste it into your LLM" : (root.svc.lastError || "could not copy"); dictStatusClear.restart() })
          }
          Button {
            id: dictPasteButton; hasCursor: root.cursorOn(dictPasteButton)
            width: (parent.width - parent.spacing * 3) / 4; text: "Paste entries"
            tooltipText: "Merge dictionary lines from the clipboard (duplicates skipped, conflicts keep yours)"
            fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
            foreground: root.foreground; fontFamily: root.fontFamily
            onClicked: if (root.svc) root.svc.dictImportClipboard(function(code, out) { root.dictStatus = code === 0 ? String(out).trim() : (root.svc.lastError || "nothing imported"); dictStatusClear.restart() })
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
            Keys.onEscapePressed: { root.dictAddOpen = false; focus = false; root.doneEditing() }
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
                dictHeard.text = ""; text = ""; root.dictAddOpen = false; focus = false; root.doneEditing()
              }
            }
            Keys.onEscapePressed: { root.dictAddOpen = false; focus = false; root.doneEditing() }
          }
        }
        Text {
          visible: root.dictStatus.length > 0
          width: parent.width; wrapMode: Text.Wrap
          text: root.dictStatus
          textFormat: Text.PlainText   // echoes the user's own dictionary words
          color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption
        }
        Timer { id: dictStatusClear; interval: 6000; onTriggered: root.dictStatus = "" }
      }
    }
  }
}
