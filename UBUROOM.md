# plezy-uburoom Architecture & Integration Specification

## Overview

`plezy-uburoom` adapts Plezy's cross-platform Flutter + `libmpv` client into a first-class native client for **uburoom**. It solves two core goals:
1. **Uburoom Anywhere**: Native playback with hardware-accelerated `libmpv` and `libass` across Windows, Android, iOS, macOS, Linux, and tvOS.
2. **Zero-Bandwidth Watch Parties with Downloaded Files**: Seamless participation in live uburoom watch parties using locally downloaded Plex media (`DownloadManagerService`), falling back to uburoom's authorized room stream (`mediaUrl` / `directHls`) whenever an item is not downloaded locally.

## End-to-End Data & Control Flow

1. **Authentication & Session Handoff**:
   - The client authenticates with an uburoom server (`https://<origin>`) via a browser handoff flow (`server/handoff.js` / `/api/watch/handoff`) or bearer token issuance (`server/watch-http.js`), storing the 64-hex-character bearer token and server origin in `CredentialVault` / `SettingsService`.
   - On connect, `UburoomSocketService` opens `wss://<origin>/watch-socket` with `Origin: <publicUrl>` and sends `{ "type": "auth", "token": "<bearer64>" }`, waiting for `{ "type": "auth-ok", "connectionId": N }`.
2. **Clock Synchronization (`/watch-socket` `clock` exchanges)**:
   - Every 1,000 ms (and on initial burst), the client sends `{ "type": "clock", "id": seq }`.
   - Using `serverReceivedAt`, `serverSentAt`, `serverProcessingMs`, and `clockEpoch` from the response, `ClockSync` computes RTT minus server processing time and maintains the server clock offset, resetting on `clockEpoch` change or clock discontinuity.
3. **Room Subscription & Media Resolution**:
   - Subscribing to a room sends a WebSocket `request` frame to `/api/watch/rooms/<roomId>?viewer=<viewerUuid>&quality=<preset>&delivery=<local|auto>`.
   - When the room's active `mediaId` (Plex `ratingKey`) changes:
     - `CurrentPlaybackDispatcher` checks Plezy's `AppDatabase` via `resolveDownloadedVideoSource()` (`lib/services/downloaded_video_source.dart`).
     - **Case A — Local Download Available (`PlaybackSourceKind.localFile`)**:
       - `plezy-uburoom` subscribes with `delivery=local`, opens the local file in `libmpv`, and attaches `AttachedPlayer` to the uburoom reconciler.
     - **Case B — Stream from Uburoom / Plex (`delivery=auto`)**:
       - `plezy-uburoom` subscribes with `delivery=auto`. If the user has a direct Plex server connection matching the item and `state.directDelivery` applies, or via uburoom's `state.mediaUrl` (`/api/watch/media/<grant>/start` or `state.directHls`), `libmpv` opens the stream URL with appropriate headers.
4. **Timeline Reconciliation & Readiness**:
   - When `state.waitingForReady` is true or `mediaVersion` changes, once `libmpv` decodes the first frame (`AttachedPlayer.firstFrameSeen`) and aligns to target position, the client sends `POST`-equivalent WebSocket request `/api/watch/rooms/<roomId>/ready` with `{ viewerId, mediaVersion, ready: true, readinessVersion }`.
   - When `state.startAt > state.serverNow` and `!state.state.paused`, the client holds `libmpv` paused at the target frame and arms a timer for `state.startAt`.
   - During active playback, the reconciler compares `expectedPosition = targetAt(serverTime)` against `libmpv.currentPosition`:
     - Drift within deadband (`<= 350 ms`): rate `1.0`.
     - Moderate drift (`350 ms` to `2000 ms`): gentle `±4%` playback rate slew (skipped when audio passthrough is active).
     - Large drift (`> 2000 ms`): guarded seek with settle window.
   - Every 4 seconds (or on status change), the client emits `{ "type": "sync-quality", roomId, viewerId, mediaVersion, streamVersion, status, score, confidence, measurementFreshnessMs }` and periodic `/api/watch/rooms/<roomId>/observe` reports.
5. **Shared Controls & Queues**:
   - Local play, pause, seek, and skip intents dispatch validated room commands over `/watch-socket` (`path: '/api/watch/rooms/<roomId>/command'`, `{ epoch, expiresAt: serverNow + 2500, viewerId, command: { action, args } }`) using the canonical actions in `shared/room-protocol.js` (`media.play`, `media.pause`, `media.seek.absolute`, `media.next`, `queue.add`, `queue.auto`, etc.).

## Phased Implementation Roadmap

### Phase 1 — Uburoom Server Support for Native Client & `delivery=local` (`C:\dev\uburoom`)
- **`server/watch-operations.js`**:
  - Accept `delivery=local` query parameter on `GET /api/watch/rooms/:id?viewer=...`.
  - When `delivery=local` is active for a viewer, record `viewer.localDelivery = true` and skip `watch.prepareViewer(room, auth.actor, viewerId)` and `mediaGrant()` so no upstream Plex HLS transcode or proxy grant is allocated, while still populating room metadata/timeline (`mediaId`, `mediaVersion`, `streamVersion`, `startAt`, `pauseAt`, `state`, `readiness`) and allowing `/ready` and `/observe`.
  - Ensure switching from `delivery=local` back to streamed delivery clears `viewer.localDelivery` and runs `prepareViewer`.
- **`server/watch-http.js` & `server/handoff.js`**:
  - Support native client bearer token handoff so `plezy-uburoom` can authenticate via system browser and receive a renewable or session-scoped 64-hex-char bearer token for `/watch-socket` and `/api/watch/media/:grant/*`.
- **Verification**: Unit tests in `tests/watch.test.js` and `tests/watch-socket.test.js` verifying `delivery=local` skips transcode allocation while preserving readiness, sync-quality, and `observe` tracking.

### Phase 2 — Unlock Downloaded Files in Plezy Watch Sessions (`C:\dev\plezy-uburoom`)
- **Decouple `_offlineLibraryMode` from `_usesLocalPlaybackSource` in `VideoPlayerScreen`**:
  - `lib/screens/video_player_screen.dart:1064`: Allow `_downloadOutranksQuality` to remain `true` (`!_qualityPresetExplicit`) when in an uburoom Watch Together session so `PlaybackSourceResolver` prefers completed local downloads.
  - `lib/screens/video_player/parts/watch_together.dart:6-12` & `lib/screens/video_player/parts/playback_start.dart:326`: Replace `!_isOfflinePlayback` with `!_offlineLibraryMode` in `_watchTogetherOwnsPlaybackStart()`, `_watchTogetherOwnsPlaybackRate()`, and `afterMediaOpened` so a local downloaded file (`PlaybackSourceKind.localFile`) still binds `AttachedPlayer` to `WatchTogetherProvider` when the app is online.
  - Suppress direct PMS timeline reporting when uburoom `observe` reporting is active so the Plex server does not receive duplicate or conflicting session states.

### Phase 3 — Uburoom `/watch-socket` Transport & Reconciler in Dart (`C:\dev\plezy-uburoom`)
- **Add `UburoomSocketService` (`lib/watch_together/services/uburoom_socket_service.dart`)**:
  - Implement WebSocket connection to `/watch-socket`, `{ type: 'auth', token }`, `{ type: 'clock', id }`, `{ type: 'request', id, path, data }`, `{ type: 'sync-quality', ... }`, and reactive handling of pushed `{ type: 'identity' }`, `{ type: 'rooms' }`, `{ type: 'state' }`, and `{ type: 'room-kicked' }` messages.
- **Adapt `ClockSync` & `GuestPlaybackReconciler` for Server-Authoritative State**:
  - Update `ClockSync` (`lib/watch_together/services/clock_sync.dart`) to consume uburoom's `{ serverNow, timing: { serverReceivedAt, serverSentAt, serverProcessingMs, clockEpoch } }`.
  - Map uburoom's room snapshot into `PlaybackState` (`anchorPositionMs`, `anchorHostTimeMs` from `startAt` / `pauseAt`, `waitingForReady`) and wire readiness (`ready`), observations (`observe`), and command dispatch (`/api/watch/rooms/:id/command`).
  - Support fallback stream playback when a room item is not downloaded locally by opening `https://<uburoom-origin><state.mediaUrl>` (with `Authorization: Bearer <token>`) or `state.directHls` in `libmpv`.

### Phase 4 — Room Lobby, Queue Drawer & End-to-End Verification
- Update `WatchTogetherScreen` (`lib/watch_together/screens/watch_together_screen.dart`) to list public/saved uburoom rooms (`/api/watch/rooms`, `/api/watch/rooms/saved`), create/reopen rooms, and display active queue / auto-queue state (`/api/watch/rooms/:id/queue`).
