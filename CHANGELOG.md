# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow SemVer.

## [Unreleased]

## [0.1.0] — 2026-08-29

### Added

* `bin/omarecorder` CLI: record (mic / system / both via `pw-record`), import, list, rename, delete (trash),
  transcribe with voxtype in a detached `systemd-run` unit, model catalog + background downloads,
  per-machine speed calibration for estimates, config, setup check.
* Bar widget + popup: record/stop toggle with timer, source picker, recent recordings, settings, setup card.
* Library overlay: search, list, editable title, model picker with estimates, transcribe/cancel, play,
  open/copy transcript, open folder, delete with confirmation, transcript view.
* Design spec: `docs/superpowers/specs/2026-08-29-omarecorder-design.md`.
