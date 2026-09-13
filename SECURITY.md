# Security

OmaRecorder records audio and stores transcripts, so security reports get
priority over everything else.

## Supported versions

The latest tagged release is the only one that gets fixes. There are no
maintenance branches: a security fix goes out as the next patch release, and
`omarchy plugin update io.github.huey-holdings-llc.omarecorder` is how you get
it. Older tags are kept for reference and are not patched.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting on this repository
(Security tab, "Report a vulnerability") rather than a public issue, so a fix
can ship before the details are out. If you cannot use that, open an issue
saying only that you have a security report and how to reach you.

You can expect an acknowledgement within a few days. This is a part-time
project, but a confirmed vulnerability will be fixed and released ahead of any
other work.

## What counts

Anything that lets a recording, transcript or note be read by another user or
leave the machine; anything that executes code from data (a file name, a
recording title, transcript text, an imported file); anything that deletes or
overwrites files outside a recording folder, other than the plugin's own config,
state and runtime files and the source of an `import --move` you asked for; anything
that weakens the file
permissions the README promises. The threat model and the promises themselves
are in the README under "Privacy and security".

## Scope notes

The transcription engine (voxtype/whisper), Quickshell, and the Omarchy shell
are separate projects; issues in them should go upstream, though a report here
that helps route the problem is still welcome.
