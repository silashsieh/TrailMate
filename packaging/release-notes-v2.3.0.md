## TrailMate 2.3.0

- Saved locations and routes now keep their order after a drag, including items in categories.
- Recordings are isolated per device session, so simultaneous captures stay in separate files.
- A closed device daemon pipe now disconnects the affected session instead of terminating TrailMate.
- After an unexpected disconnect, a previously connected session can retry automatically. The first and subsequent attempts start after a five-second delay, for up to ten attempts. An explicit Disconnect or Cancel retry stops recovery.
- Expanded automated coverage for device discovery, connection selection, session transitions, recording, offline routes, command dispatch, and UI workflows.

🤖 Generated with Codex for release-owner review.
