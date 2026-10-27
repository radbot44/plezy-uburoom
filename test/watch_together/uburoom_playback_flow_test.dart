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

  @override
  void dispose() {
    stateController.close();
    super.dispose();
  }

  @override
  bool get isConnected => true;

  @override
  UburoomConnectionState get state => UburoomConnectionState.connected;

  @override
  String get serverUrl => 'http://localhost:6767';

  @override
  String get token => 'test-bearer-token-64hex';

  @override
  Stream<UburoomRoomStatePush> get roomStateStream => stateController.stream;

  @override
  Future<UburoomResponse> sendRequest(String path, [Map<String, dynamic>? data]) async {
    requests.add({'path': path, 'data': data});
    return const UburoomResponse(id: 1, status: 200, value: {'ok': true});
  }
}

class _SyncPlayer extends FakeSyncPlayer {
  _SyncPlayer({super.hasRenderedFrame});

  @override
  PlayerStreams get streams => emptyPlayerStreams();
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
}
