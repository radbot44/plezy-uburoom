import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/watch_together/models/watch_copy.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/watch_together/services/clock_sync.dart';
import 'package:plezy/watch_together/services/player_adapter.dart';
import 'package:plezy/watch_together/services/uburoom_auth_service.dart';
import 'package:plezy/watch_together/services/uburoom_socket_service.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/player_streams.dart';
import '../test_helpers/watch_together_fakes.dart';

class _FakeAuth extends UburoomAuthService {
  @override
  String get serverUrl => 'http://localhost:6767';
  @override
  Future<String?> getToken() async => 'test-bearer-token-64hex';
}

class _TestSocket extends UburoomSocketService {
  _TestSocket({required super.clockSync});

  final requests = <Map<String, dynamic>>[];
  final stateController = StreamController<UburoomRoomStatePush>.broadcast();
  final connectionController = StreamController<UburoomConnectionState>.broadcast();
  UburoomConnectionState _currentState = UburoomConnectionState.connected;
  UburoomResponse Function(String path, Map<String, dynamic>? data)? onSendRequest;

  @override
  void dispose() {
    stateController.close();
    connectionController.close();
    super.dispose();
  }

  @override
  bool get isConnected => _currentState == UburoomConnectionState.connected;

  @override
  UburoomConnectionState get state => _currentState;

  void emitConnectionState(UburoomConnectionState newState) {
    _currentState = newState;
    connectionController.add(newState);
  }

  @override
  Stream<UburoomConnectionState> get connectionStateStream => connectionController.stream;

  @override
  String get serverUrl => 'http://localhost:6767';

  @override
  String get token => 'test-bearer-token-64hex';

  @override
  Stream<UburoomRoomStatePush> get roomStateStream => stateController.stream;

  @override
  Future<UburoomResponse> sendRequest(String path, [Map<String, dynamic>? data]) async {
    requests.add({'path': path, 'data': data});
    if (onSendRequest != null) {
      return onSendRequest!(path, data);
    }
    return const UburoomResponse(id: 1, status: 200, value: {'ok': true});
  }
}

class _SyncPlayer extends FakeSyncPlayer {
  _SyncPlayer({super.hasRenderedFrame});

  @override
  PlayerStreams get streams => emptyPlayerStreams(playbackRestart: super.streams.playbackRestart);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ClockSync clockSync;
  late _TestSocket socket;
  late _FakeAuth auth;
  late WatchTogetherProvider provider;

  setUp(() {
    clockSync = ClockSync();
    clockSync.addSample(
      localSendAt: 1000,
      serverReceivedAt: 1005,
      serverSentAt: 1005,
      localReceiveAt: 1010,
      serverProcessingMs: 0,
      clockEpoch: 1,
    );
    socket = _TestSocket(clockSync: clockSync);
    auth = _FakeAuth();
    provider = WatchTogetherProvider(
      socketService: socket,
      authService: auth,
      clockSync: clockSync,
      viewerId: 'viewer-uuid-42',
    );
    provider.setUburoomSessionForTest(
      roomId: 'room-uuid-1',
      serverUrl: 'http://localhost:6767',
      token: 'test-bearer-token-64hex',
    );
  });

  tearDown(() {
    provider.dispose();
  });

  test('parses real server snapshot with top-level mediaId and seconds timeline', () {
    final snapshot = {
      'id': 'room-uuid-1',
      'roomName': 'Friday Movie Night',
      'epoch': 'epoch-uuid-99',
      'revision': 12,
      'mediaVersion': 'mv-uuid-1',
      'streamVersion': 'sv-uuid-1',
      'mediaId': '98765',
      'title': 'Blade Runner 2049',
      'subtitle': 'Sci-Fi / Action',
      'mediaUrl': '/api/watch/media/grant-uuid-1/start',
      'readinessVersion': 'ready-uuid-77',
      'waitingForReady': true,
      'serverNow': clockSync.serverNow,
      'startAt': clockSync.serverNow + 3000,
      'pauseAt': null,
      'isHost': true,
      'canPlayback': true,
      'canManage': true,
      'viewers': 2,
      'participants': [
        {'id': 'viewer-uuid-42', 'name': 'Host User', 'role': 'host', 'isHost': true, 'present': true},
        {
          'id': 'viewer-uuid-2',
          'name': 'Guest User',
          'role': 'viewer',
          'isHost': false,
          'present': true,
          'syncQuality': {'status': 'playing', 'level': 'excellent', 'score': 1.0},
        },
      ],
      'state': {'position': 125.5, 'duration': 9840.0, 'paused': true, 'rate': 1.0},
    };

    provider.handleUburoomSnapshotForTest(snapshot);

    expect(provider.isUburoomSession, isTrue);
    expect(provider.isConnected, isTrue);
    expect(provider.isHost, isTrue);
    expect(provider.canControl, isTrue);
    expect(provider.hasMedia, isTrue);
    expect(provider.roomCode, 'room-uuid-1');

    final ubState = provider.uburoomState;
    expect(ubState, isNotNull);
    expect(ubState!.roomName, 'Friday Movie Night');
    expect(ubState.mediaId, '98765');
    expect(ubState.title, 'Blade Runner 2049');
    expect(ubState.subtitle, 'Sci-Fi / Action');
    expect(ubState.readinessVersion, 'ready-uuid-77');
    expect(ubState.waitingForReady, isTrue);
    expect(ubState.positionSeconds, 125.5);
    expect(ubState.durationSeconds, 9840.0);
    expect(ubState.paused, isTrue);
    expect(ubState.participants, hasLength(2));
    expect(ubState.participants.first.name, 'Host User');
    expect(ubState.participants.first.isHost, isTrue);
    expect(ubState.participants.last.syncLevel, 'excellent');

    // Check generated roomCopy
    final copy = provider.roomCopy?.ref;
    expect(copy, isNotNull);
    expect(copy!.itemId, '98765');
    expect(copy.item, isNotNull);
    expect(copy.item!.title, 'Blade Runner 2049');
    expect(copy.item!.durationMs, 9840000);
    expect(copy.item!.raw?['uburoomMediaUrl'], 'http://localhost:6767/api/watch/media/grant-uuid-1/start');
    expect(copy.item!.raw?['uburoomHeaders'], {'Authorization': 'Bearer test-bearer-token-64hex'});
    expect(provider.canJoinPlayback, isTrue);
  });

  test('empty room transitions to media selected without auto-pushing when player is null', () {
    // 1. Initial empty room
    final emptySnapshot = {
      'id': 'room-uuid-1',
      'roomName': 'Lobby',
      'epoch': 'epoch-uuid-1',
      'revision': 1,
      'mediaId': null,
      'title': 'Choose something to watch…',
      'subtitle': '',
      'mediaUrl': null,
      'state': {'position': 0, 'duration': 0, 'paused': true},
      'participants': [],
    };
    provider.handleUburoomSnapshotForTest(emptySnapshot);

    expect(provider.hasMedia, isFalse);
    expect(provider.roomCopy, isNull);
    expect(provider.canJoinPlayback, isFalse);

    // 2. Media is selected in room
    final mediaSnapshot = {
      'id': 'room-uuid-1',
      'roomName': 'Lobby',
      'epoch': 'epoch-uuid-2',
      'revision': 2,
      'mediaId': '555',
      'title': 'Interstellar',
      'subtitle': 'Sci-Fi',
      'mediaUrl': '/api/watch/media/grant-2/start',
      'state': {'position': 0, 'duration': 10140, 'paused': true},
      'participants': [],
    };
    provider.handleUburoomSnapshotForTest(mediaSnapshot);

    expect(provider.hasMedia, isTrue);
    expect(provider.roomCopy, isNotNull);
    expect(provider.canJoinPlayback, isTrue);
    // Player was not open, so it did NOT auto-launch; user clicks "Join Playback"
  });

  test('in-player auto-sync: switches open player in place and exits when media clears', () async {
    final mediaItem1 = testMediaItem(id: '100', title: 'Part 1', serverId: 'uburoom');
    final copy1 = WatchCopy(serverId: 'uburoom', itemId: '100', versionId: '', item: mediaItem1);
    final player = _SyncPlayer(hasRenderedFrame: true);
    final adapter = PlezyPlayerAdapter(
      player: player,
      copy: copy1,
      commands: PlayerCommands(play: () async {}, pause: () async {}, seek: (_) async {}, setRate: (_) async {}),
    );

    WatchCopy? openedInPlaceCopy;
    bool exitedPlayer = false;

    provider.registerPlayer(
      'test-owner',
      WatchPlayerHooks(
        openInPlace: (copy) async {
          openedInPlaceCopy = copy;
          return true;
        },
        exitPlayer: () {
          exitedPlayer = true;
        },
      ),
    );

    provider.playerOpened(adapter, shareable: true, roomLaunch: false);
    expect(provider.follows(adapter), isFalse); // not yet matching room media

    // Room selects item 100
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'epoch': 'ep-1',
      'revision': 1,
      'mediaId': '100',
      'title': 'Part 1',
      'mediaUrl': '/api/watch/media/g1/start',
      'state': {'position': 10, 'duration': 100, 'paused': true},
    });
    expect(provider.follows(adapter), isTrue);

    // Room switches to item 200
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'epoch': 'ep-2',
      'revision': 2,
      'mediaId': '200',
      'title': 'Part 2',
      'mediaUrl': '/api/watch/media/g2/start',
      'state': {'position': 0, 'duration': 200, 'paused': true},
    });
    expect(openedInPlaceCopy?.itemId, '200');

    // Room clears media
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'epoch': 'ep-3',
      'revision': 3,
      'mediaId': null,
      'title': 'Choose something to watch…',
      'mediaUrl': null,
      'state': {'position': 0, 'duration': 0, 'paused': true},
    });
    expect(exitedPlayer, isTrue);
  });

  test('media.seek.absolute command sends seconds to uburoom', () {
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'epoch': 'ep-seek',
      'revision': 1,
      'mediaId': '100',
      'canPlayback': true,
      'state': {'position': 0, 'duration': 100, 'paused': true},
    });

    final player = _SyncPlayer(hasRenderedFrame: true);
    final copy = WatchCopy(
      serverId: 'uburoom',
      itemId: '100',
      versionId: '',
      item: testMediaItem(id: '100'),
    );
    final adapter = PlezyPlayerAdapter(
      player: player,
      copy: copy,
      commands: PlayerCommands(play: () async {}, pause: () async {}, seek: (_) async {}, setRate: (_) async {}),
    );
    provider.playerOpened(adapter, shareable: true, roomLaunch: false);

    // Seek to 42.5 seconds (42500 ms)
    provider.seek(const Duration(milliseconds: 42500));

    final lastReq = socket.requests.last;
    expect(lastReq['path'], '/api/watch/rooms/room-uuid-1/command');
    final cmd = lastReq['data']?['command'];
    expect(cmd?['action'], 'media.seek.absolute');
    expect(cmd?['args']?['seconds'], 42.5);
  });

  test('playerClosed does not disconnect the uburoom socket or room subscriptions', () async {
    final player = _SyncPlayer(hasRenderedFrame: true);
    final copy = WatchCopy(
      serverId: 'uburoom',
      itemId: '100',
      versionId: '',
      item: testMediaItem(id: '100'),
    );
    final adapter = PlezyPlayerAdapter(
      player: player,
      copy: copy,
      commands: PlayerCommands(play: () async {}, pause: () async {}, seek: (_) async {}, setRate: (_) async {}),
    );
    provider.playerOpened(adapter, shareable: true, roomLaunch: false);

    await provider.playerClosed(adapter, continuing: false);

    expect(provider.isUburoomSession, isTrue);
    expect(provider.isConnected, isTrue);
    expect(socket.isConnected, isTrue);
  });

  test('endRoom sends epoch string and closes room', () {
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'epoch': 'full-uuid-epoch-1234',
      'revision': 1,
      'isHost': true,
      'state': {'position': 0, 'duration': 100, 'paused': true},
    });

    provider.endRoom();

    final closeReq = socket.requests.firstWhere((r) => r['path'] == '/api/watch/rooms/room-uuid-1/close');
    expect(closeReq['data']?['epoch'], 'full-uuid-epoch-1234');
    expect(provider.isUburoomSession, isFalse);
  });

  test('loadMediaInUburoom dispatches media.load command with direct quality', () async {
    final item = testMediaItem(id: '54321', title: 'Arrival');
    await provider.loadMediaInUburoom(item);

    final req = socket.requests.lastWhere((r) => r['path'] == '/api/watch/rooms/room-uuid-1/command');
    final cmd = req['data']?['command'];
    expect(cmd?['action'], 'media.load');
    expect(cmd?['args']?['mediaId'], '54321');
    expect(cmd?['args']?['quality'], 'direct');
  });

  test('loadMediaInUburoom in durable room uses queue playNow', () async {
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'durable': true,
      'epoch': 'epoch-durable-1',
      'state': {'position': 0, 'duration': 100, 'paused': true},
    });

    final item = testMediaItem(id: '67890', title: 'Interstellar');
    await provider.loadMediaInUburoom(item);

    final req = socket.requests.lastWhere((r) => r['path'] == '/api/watch/rooms/room-uuid-1/queue');
    expect(req['data']?['action'], 'playNow');
    expect(req['data']?['item']?['mediaId'], '67890');
    expect(req['data']?['item']?['title'], 'Interstellar');
  });

  test('addMediaToUburoomQueue dispatches queue add action', () async {
    final item = testMediaItem(id: '11223', title: 'Dune');
    await provider.addMediaToUburoomQueue(item);

    final req = socket.requests.lastWhere((r) => r['path'] == '/api/watch/rooms/room-uuid-1/queue');
    expect(req['data']?['action'], 'add');
    expect(req['data']?['item']?['mediaId'], '11223');
    expect(req['data']?['item']?['title'], 'Dune');
  });

  test('playerOpened with different library item in room triggers loadMediaInUburoom', () async {
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'mediaId': '100',
      'isHost': true,
      'epoch': 'ep-1',
      'state': {'position': 0, 'duration': 100, 'paused': true},
    });

    final player = _SyncPlayer(hasRenderedFrame: true);
    final copy = WatchCopy(
      serverId: 'srv',
      itemId: '200',
      versionId: '',
      item: testMediaItem(id: '200', title: 'New Movie'),
    );
    final adapter = PlezyPlayerAdapter(
      player: player,
      copy: copy,
      commands: PlayerCommands(play: () async {}, pause: () async {}, seek: (_) async {}, setRate: (_) async {}),
    );

    provider.playerOpened(adapter, shareable: true, roomLaunch: false);

    final req = socket.requests.lastWhere((r) => r['path'] == '/api/watch/rooms/room-uuid-1/command');
    expect(req['data']?['command']?['action'], 'media.load');
    expect(req['data']?['command']?['args']?['mediaId'], '200');
  });

  test('reconciler seeks during waitingForReady and only sends ready after aligning to target position', () async {
    int seekCallCount = 0;
    int targetSeekPos = -1;

    final player = _SyncPlayer(hasRenderedFrame: true);
    final adapter = PlezyPlayerAdapter(
      player: player,
      copy: WatchCopy(
        serverId: 'srv',
        itemId: '1',
        versionId: '',
        item: testMediaItem(id: '1'),
      ),
      commands: PlayerCommands(
        play: () async {},
        pause: () async {},
        seek: (Duration pos) async {
          seekCallCount++;
          targetSeekPos = pos.inMilliseconds;
          await player.seek(pos);
        },
        setRate: (_) async {},
      ),
    );

    provider.playerOpened(adapter, shareable: true, roomLaunch: false);

    // Initial snapshot: room seeks to 50.0 seconds with readinessVersion UUID
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'mediaVersion': 'mv-1',
      'streamVersion': 'sv-1',
      'readinessVersion': 'seek-uuid-1234',
      'waitingForReady': true,
      'state': {'position': 50.0, 'duration': 100.0, 'paused': true},
    });
    await pumpEventQueue();

    // Player starts at position 0, so drift is 50000 ms (> 50 ms threshold)
    expect(seekCallCount, 1);
    expect(targetSeekPos, 50000);

    // Ready should now be sent for seek-uuid-1234 because drift is now 0 (<= 500)
    final readyReq = socket.requests.firstWhere((r) => r['path'] == '/api/watch/rooms/room-uuid-1/ready');
    expect(readyReq['data']?['mediaVersion'], 'mv-1');
    expect(readyReq['data']?['readinessVersion'], 'seek-uuid-1234');
    expect(readyReq['data']?['ready'], isTrue);
  });

  test('socket reconnect restores active room subscription and updates snapshot', () async {
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'epoch': 'ep-init',
      'mediaId': 'm-1',
      'title': 'Initial Title',
      'state': {'position': 0, 'duration': 100, 'paused': true},
    });

    socket.onSendRequest = (path, data) {
      if (path.contains('/api/watch/rooms/room-uuid-1?')) {
        return const UburoomResponse(
          id: 11,
          status: 200,
          value: {
            'id': 'room-uuid-1',
            'epoch': 'ep-reconnected',
            'mediaId': 'm-2',
            'title': 'Updated Title After Reconnect',
            'state': {'position': 45, 'duration': 100, 'paused': false},
          },
        );
      }
      return const UburoomResponse(id: 1, status: 200, value: {'ok': true});
    };

    // Emit reconnect
    socket.emitConnectionState(UburoomConnectionState.connected);
    await pumpEventQueue();

    expect(provider.debugUburoomEpoch, 'ep-reconnected');
    expect(provider.uburoomState?.title, 'Updated Title After Reconnect');
    final subReq = socket.requests.lastWhere((r) => (r['path'] as String).contains('/api/watch/rooms/room-uuid-1?'));
    expect(subReq['path'], contains('quality=direct'));
    expect(subReq['path'], contains('delivery=auto'));
  });

  test('play and pause from lobby send room commands when player is not open', () async {
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'mediaId': '100',
      'isHost': true,
      'canPlayback': true,
      'epoch': 'ep-1',
      'state': {'position': 10, 'duration': 100, 'paused': true},
    });

    expect(provider.isFollowing, isFalse);
    expect(provider.canControl, isTrue);

    final playResult = provider.play();
    expect(playResult, isTrue);

    final playReq = socket.requests.lastWhere((r) => r['path'] == '/api/watch/rooms/room-uuid-1/command');
    expect(playReq['data']?['command']?['action'], 'media.play');

    final pauseResult = provider.pause();
    expect(pauseResult, isTrue);

    final pauseReq = socket.requests.lastWhere((r) => r['path'] == '/api/watch/rooms/room-uuid-1/command');
    expect(pauseReq['data']?['command']?['action'], 'media.pause');
  });

  test('play and pause from lobby refuse when user cannot control playback', () async {
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'mediaId': '100',
      'isHost': false,
      'canPlayback': false,
      'epoch': 'ep-1',
      'state': {'position': 10, 'duration': 100, 'paused': true},
    });

    expect(provider.canControl, isFalse);
    expect(provider.play(), isFalse);
    expect(provider.pause(), isFalse);
  });

  test('loadMediaInUburoom and addMediaToUburoomQueue provide fallback duration when durationMs is null', () async {
    final item = testMediaItem(id: '999', title: 'Stream With Unknown Duration', durationMs: null);

    // 1. loadMediaInUburoom in durable room uses queue playNow with duration 1.0
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'durable': true,
      'epoch': 'ep-dur',
      'state': {'position': 0, 'duration': 100, 'paused': true},
    });
    await provider.loadMediaInUburoom(item);
    final playNowReq = socket.requests.lastWhere((r) => r['path'] == '/api/watch/rooms/room-uuid-1/queue');
    expect(playNowReq['data']?['item']?['duration'], 1.0);

    // 2. addMediaToUburoomQueue uses duration 1.0
    await provider.addMediaToUburoomQueue(item);
    final addReq = socket.requests.lastWhere((r) => r['path'] == '/api/watch/rooms/room-uuid-1/queue');
    expect(addReq['data']?['item']?['duration'], 1.0);
  });

  test('handleUburoomSnapshot switches delivery back to auto when item is not downloaded', () async {
    provider.debugUburoomDelivery = 'local';

    socket.onSendRequest = (path, data) {
      if (path.contains('delivery=auto')) {
        return const UburoomResponse(
          id: 10,
          status: 200,
          value: {
            'id': 'room-uuid-1',
            'epoch': 'ep-auto-1',
            'mediaId': 'stream-only-item',
            'title': 'Online Stream',
            'mediaUrl': '/api/watch/media/grant-auto/start',
            'state': {'position': 0, 'duration': 100, 'paused': true},
          },
        );
      }
      return const UburoomResponse(id: 1, status: 200, value: {'ok': true});
    };

    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'epoch': 'ep-auto-0',
      'mediaId': 'stream-only-item',
      'title': 'Online Stream',
      'mediaUrl': '/api/watch/media/grant-auto/start',
      'state': {'position': 0, 'duration': 100, 'paused': true},
    });
    await pumpEventQueue();

    expect(provider.debugUburoomDelivery, 'auto');
    final switchReq = socket.requests.firstWhere((r) => (r['path'] as String).contains('delivery=auto'));
    expect(switchReq['path'], contains('quality=direct'));
    expect(switchReq['path'], contains('delivery=auto'));
  });

  test('stopMedia in uburoom durable room clears queue and does not send unsupported media.stop', () async {
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'durable': true,
      'epoch': 'ep-durable',
      'state': {'position': 10, 'duration': 100, 'paused': false},
    });

    provider.stopMedia();
    await pumpEventQueue();

    final clearReq = socket.requests.lastWhere((r) => r['path'] == '/api/watch/rooms/room-uuid-1/command');
    expect(clearReq['data']?['command']?['action'], 'queue.clear');
    final hasMediaStop = socket.requests.any((r) => r['data']?['command']?['action'] == 'media.stop');
    expect(hasMediaStop, isFalse);
  });

  test('setRate in uburoom session does not send unsupported media.rate command', () async {
    provider.handleUburoomSnapshotForTest({
      'id': 'room-uuid-1',
      'epoch': 'ep-1',
      'state': {'position': 10, 'duration': 100, 'paused': false},
    });

    provider.setRate(1.5);
    await pumpEventQueue();

    final hasMediaRate = socket.requests.any((r) => r['data']?['command']?['action'] == 'media.rate');
    expect(hasMediaRate, isFalse);
  });
}
