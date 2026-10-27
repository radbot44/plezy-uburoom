# Working on plezy-uburoom

## Scope and authority

- `plezy-uburoom` is a hybrid native client fork of Plezy (`Flutter` + `libmpv`) designed to operate as a companion client for self-hosted **uburoom** servers (`C:\dev\uburoom`) while retaining direct Plex Media Server connectivity for browsing and offline downloads.
- Follow the owner's current task and read `UBUROOM.md` before planning or modifying room synchronization, authentication, or playback source resolution.
- Present concrete code locations, architectural tradeoffs, a staged plan, and numbered questions before implementing non-trivial changes or UI modifications. Wait for explicit owner approval before mutating production behavior or expanding scope.

## Core architectural invariants

1. **Hybrid Direct-Plex + Uburoom Room Sync**:
   - Do **not** replace `PlexClient` (`lib/services/plex_client.dart`) or `DownloadManagerService` (`lib/services/download_manager_service.dart`) with uburoom catalog calls. Plezy connects directly to Plex for library browsing, metadata, and offline file downloads.
   - Integrate uburoom at the `lib/watch_together/` and `VideoPlayerScreen` layers so watch rooms synchronize over uburoom's `/watch-socket` WebSocket endpoint.
2. **Downloaded Files in Watch Rooms (`delivery=local`)**:
   - Upstream Plezy conflates offline library mode (`_offlineLibraryMode`) with local file playback (`_effectiveIsOffline` / `PlaybackSourceKind.localFile`) via `_isOfflinePlayback`, which disables Watch Together when a downloaded file is opened (`lib/screens/video_player_screen.dart:1064`, `lib/screens/video_player/parts/watch_together.dart:6-12`, `lib/screens/video_player/parts/playback_start.dart:326`).
   - In `plezy-uburoom`, separate **network availability** (`!_offlineLibraryMode`) from **media source location** (`_usesLocalPlaybackSource` / `PlaybackSourceKind.localFile`).
   - When an uburoom session is active and a matching downloaded copy exists (`resolveDownloadedVideoSource` in `lib/services/downloaded_video_source.dart`), open the local file in `libmpv`, attach `AttachedPlayer` to the uburoom session, and subscribe to `/api/watch/rooms/:id?viewer=...&delivery=local` so the uburoom server skips upstream HLS/proxy allocation while retaining readiness gates, clock sync, and `observe` reporting.
   - When no local download exists (or when the viewer is a sponsored guest without personal Plex access), open uburoom's authorized `state.mediaUrl` (`/api/watch/media/:grant/start`) or `state.directHls` stream in `libmpv`.
3. **Server-Authoritative Timeline & Reporting**:
   - Uburoom's server owns the room timeline (`epoch`, `revision`, `mediaVersion`, `streamVersion`, `startAt`, `pauseAt`, `serverNow`, `waitingForReady`). Every `plezy-uburoom` client acts as a synchronized room viewer rather than running P2P host heartbeats (`HostPlaybackCoordinator`).
   - While in an active uburoom room, suppress duplicate direct-to-PMS `/:/timeline` reporting in Plezy (`PlaybackReportingMode`) and route decoded playback observations through uburoom's `/api/watch/rooms/:id/observe` endpoint so `server/plex-reporting.js` enforces shared-producer safety and personal watch-state opt-in rules.

## Code quality and verification

- Run `dart format .` and `flutter analyze` after Dart changes.
- If Freezed or JSON models change, run `scripts/codegen.sh`.
- Run focused unit tests via `flutter test <path>` (e.g., `flutter test test/watch_together/`) and corresponding Node tests in `C:\dev\uburoom` (`node --test ...`) when server contracts change.
- Never hardcode personal URLs, tokens, server IDs, or credentials in source or tests.
