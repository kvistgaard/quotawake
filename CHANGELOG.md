# Changelog

All notable changes to quotawake are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `qw -Open` to open the session resumed for the current folder
- `-Doctor` checks for the Claude Code version, the running sessions list and Claude's own auto-continue setting

### Changed

- quotawake now needs Claude Code 2.1.285 or later
- A resumed session now keeps the id of the session that stopped
- If an open window is still stopped ten minutes after the reset, it is now closed and its session continues in the background
- If you type into the open window within ten minutes of the reset, quotawake now leaves the session to you
- The note and the toast now say what to do, in one line
- A stop is now given up on 24 hours after its reset, with a note
- If the list of running sessions is unavailable, resumes now go ahead

### Fixed

- If a window wakes up after its session was copied, the work no longer runs twice
- A session that is waiting no longer makes quotawake give up on other sessions
- A resumed session no longer shows as having hit the limit again
- With no project folder recorded, the note no longer fails

### Removed

- The nudge to an open window
