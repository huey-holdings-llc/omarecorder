// Shared formatting for the QML side. One place for every time/size/date string
// the widgets show; the CLI keeps its own bash equivalents.
.pragma library

// 01:02:03
function fmtHms(s) {
  s = Math.max(0, Math.floor(s || 0))
  var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60
  return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m + ":" + (x < 10 ? "0" : "") + x
}
// 1:02:03 or 02:03 (positions on the waveform)
function fmtClock(s) {
  s = Math.max(0, Math.floor(s || 0))
  var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60
  return (h > 0 ? h + ":" : "") + (m < 10 ? "0" : "") + m + ":" + (x < 10 ? "0" : "") + x
}
// 1h 02m / 12m 05s / 45s
function fmtDuration(s) {
  s = Math.max(0, Math.floor(s || 0))
  var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60
  if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m"
  if (m > 0) return m + "m " + (x < 10 ? "0" : "") + x + "s"
  return x + "s"
}
// "2026-08-29T19:27:42-0400" -> "Aug 29, 19:27"
function fmtDate(iso) {
  if (!iso) return ""
  var d = new Date(String(iso).replace(/([+-]\d\d)(\d\d)$/, "$1:$2"))
  if (isNaN(d.getTime())) return String(iso).slice(0, 16).replace("T", " ")
  return Qt.formatDateTime(d, "MMM d, HH:mm")
}
// 1.2 GB / 466 MB / 12 KB
function fmtBytes(b) {
  b = b || 0
  if (b > 1e9) return (b / 1e9).toFixed(1) + " GB"
  if (b > 1e6) return Math.round(b / 1e6) + " MB"
  return Math.round(b / 1e3) + " KB"
}
