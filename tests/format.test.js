// Unit tests for ui/format.js, run under node by tests/lint.sh:
//   { echo "$QT_STUB"; sed '/^\.pragma/d' ui/format.js; cat tests/format.test.js; } | TZ=UTC node -
// The only Qt dependency in format.js is Qt.formatDateTime; lint.sh supplies a
// stub with the one format the file uses ("MMM d, HH:mm"). Keep the JS here
// ES5-flavoured, like format.js, so node and Qt's engine agree.

var failed = 0, passed = 0
function eq(desc, got, want) {
  if (got === want) { passed++ }
  else { failed++; console.log("  ✗ " + desc + "\n      got " + JSON.stringify(got) + " expected " + JSON.stringify(want)) }
}

// fmtHms: always HH:MM:SS
eq("fmtHms 0", fmtHms(0), "00:00:00")
eq("fmtHms 59", fmtHms(59), "00:00:59")
eq("fmtHms 60", fmtHms(60), "00:01:00")
eq("fmtHms 3599", fmtHms(3599), "00:59:59")
eq("fmtHms 3600", fmtHms(3600), "01:00:00")
eq("fmtHms 2 h 3 m 4 s", fmtHms(7384), "02:03:04")
eq("fmtHms floors fractions", fmtHms(61.9), "00:01:01")
eq("fmtHms clamps negatives", fmtHms(-5), "00:00:00")
eq("fmtHms undefined is zero", fmtHms(undefined), "00:00:00")
eq("fmtHms null is zero", fmtHms(null), "00:00:00")
eq("fmtHms NaN is zero", fmtHms(NaN), "00:00:00")

// fmtClock: hours only when there are any
eq("fmtClock 5", fmtClock(5), "00:05")
eq("fmtClock 65", fmtClock(65), "01:05")
eq("fmtClock 3600", fmtClock(3600), "1:00:00")
eq("fmtClock 3661", fmtClock(3661), "1:01:01")
eq("fmtClock 36000", fmtClock(36000), "10:00:00")
eq("fmtClock negative", fmtClock(-1), "00:00")

// fmtDuration: the coarse label
eq("fmtDuration 0", fmtDuration(0), "0s")
eq("fmtDuration 45", fmtDuration(45), "45s")
eq("fmtDuration 60", fmtDuration(60), "1m 00s")
eq("fmtDuration 725", fmtDuration(725), "12m 05s")
eq("fmtDuration 3600", fmtDuration(3600), "1h 00m")
eq("fmtDuration 3720", fmtDuration(3720), "1h 02m")
eq("fmtDuration 2 h 59 m 59 s rounds down to minutes", fmtDuration(10799), "2h 59m")
eq("fmtDuration null", fmtDuration(null), "0s")

// fmtBytes: strict thresholds, pinned so a change is a decision
eq("fmtBytes 0", fmtBytes(0), "0 KB")
eq("fmtBytes 512", fmtBytes(512), "1 KB")
eq("fmtBytes 12 KB", fmtBytes(12345), "12 KB")
eq("fmtBytes 1e6 is still KB (strict >)", fmtBytes(1e6), "1000 KB")
eq("fmtBytes 466 MB", fmtBytes(466e6), "466 MB")
eq("fmtBytes 1e9 is still MB (strict >)", fmtBytes(1e9), "1000 MB")
eq("fmtBytes 1.2 GB", fmtBytes(1.2e9), "1.2 GB")
eq("fmtBytes undefined", fmtBytes(undefined), "0 KB")

// fileUrl: '#' and '?' are legal in file names but would be read as fragment/query
eq("fileUrl plain", fileUrl("/home/u/Recordings/a/audio.wav"), "file:///home/u/Recordings/a/audio.wav")
eq("fileUrl space", fileUrl("/home/u/My Take/audio.wav"), "file:///home/u/My%20Take/audio.wav")
eq("fileUrl hash", fileUrl("/home/u/Take #2/audio.wav"), "file:///home/u/Take%20%232/audio.wav")
eq("fileUrl question mark", fileUrl("/home/u/Why?/audio.wav"), "file:///home/u/Why%3F/audio.wav")
eq("fileUrl percent is escaped", fileUrl("/home/u/100%/a.wav"), "file:///home/u/100%25/a.wav")
eq("fileUrl unicode", fileUrl("/home/u/Übung/a.wav"), "file:///home/u/%C3%9Cbung/a.wav")

// fmtDate: the CLI writes "%FT%T%z" (no colon in the offset); the stub formats in UTC
eq("fmtDate ISO with offset", fmtDate("2026-08-29T19:27:42-0400"), "Aug 29, 23:27")
eq("fmtDate ISO with +0000", fmtDate("2026-01-02T03:04:05+0000"), "Jan 2, 03:04")
eq("fmtDate empty", fmtDate(""), "")
eq("fmtDate null", fmtDate(null), "")
eq("fmtDate unparseable falls back to a trimmed string", fmtDate("not a date"), "not a date")
eq("fmtDate odd but sliceable string", fmtDate("2026-13-45T99:99:99+0000"), "2026-13-45 99:99")

console.log("format.js: passed " + passed + "  failed " + failed)
if (failed > 0) process.exit(1)
