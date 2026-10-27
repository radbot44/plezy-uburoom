import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/watch_together/models/watch_copy.dart';
import 'package:plezy/watch_together/services/clock_sync.dart';
import 'package:plezy/watch_together/services/guest_playback_reconciler.dart';
import 'package:plezy/watch_together/services/player_adapter.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/watch_together/services/uburoom_socket_service.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/player_streams.dart';
import '../test_helpers/watch_together_fakes.dart';

class _FakeChannel extends StreamChannelMixin<dynamic> implements WebSocketChannel {
  @override
  Stream<dynamic> get stream => const Stream.empty();
  @override
  // ignore: close_sinks
  final WebSocketSink sink = _FakeSink();
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  Future<void> get ready => Future.value();
}

class _FakeSink implements WebSocketSink {
  @override
  Future<dynamic> get done => Future.value();
  @override
  void add(dynamic data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream stream) => Future.value();
  @override
  Future close([int? closeCode, String? closeReason]) => Future.value();
}

class _TestSocketService extends UburoomSocketService {
  _TestSocketService({required super.clockSync}) : super(channelFactory: (uri, origin) async => _FakeChannel());

  final requests = <Map<String, dynamic>>[];
  // ignore: close_sinks
  final stateController = StreamController<UburoomRoomStatePush>.broadcast();
  UburoomResponse Function(String path, Map<String, dynamic>? data)? onSendRequest;

  @override
  bool get isConnected => true;

  @override
  Stream<UburoomRoomStatePush> get roomStateStream => stateController.stream;

  @override
  Future<UburoomResponse> sendRequest(String path, [Map<String, dynamic>? data]) async {
    requests.add({'path': path, 'body': data});
    if (onSendRequest != null) {
      return onSendRequest!(path, data);
    }
    return const UburoomResponse(id: 1, status: 200, value: {'ok': true});
  }
}

class _SyncPlayer extends FakeSyncPlayer {
  _SyncPlayer({super.playing, super.position, super.hasRenderedFrame, this.completedStream});

  final Stream<bool>? completedStream;

  @override
  PlayerStreams get streams => emptyPlayerStreams(
    completed: completedStream ?? const Stream.empty(),
    playbackRestart: Stream<void>.multi((controller) {
      final subscription = super.streams.playbackRestart.listen(controller.addSync);
      controller.onCancel = () {
        unawaited(subscription.cancel());
        return Future<void>.value();
      };
    }, isBroadcast: true),
  );
}

WatchCopy _testCopy() {
  final item = testMediaItem(id: 'movie-1', title: 'Alien', serverId: 'nas', durationMs: 7200000);
  return WatchCopy.of(item, null);
}

void _seedClock(ClockSync clockSync) {
  clockSync.addSample(
    localSendAt: 1000,
    serverReceivedAt: 1005,
    serverSentAt: 1005,
    serverProcessingMs: 0,
    localReceiveAt: 1010,
    clockEpoch: '1',
  );
  clockSync.addSample(
    localSendAt: 2000,
    serverReceivedAt: 2005,
    serverSentAt: 2005,
    serverProcessingMs: 0,
    localReceiveAt: 2010,
    clockEpoch: '1',
  );
}

void main() {
  group('GuestPlaybackReconciler', () {
    test('sends ready when firstFrameShown is true and room waits for ready', () {
      fakeAsync((async) {
        final clockSync = ClockSync();
        _seedClock(clockSync);

        final socketService = _TestSocketService(clockSync: clockSync);
        final player = _SyncPlayer(hasRenderedFrame: true);
        final adapter = PlezyPlayerAdapter(
          player: player,
          copy: _testCopy(),
          commands: PlayerCommands(
            play: () => player.play(),
            pause: () => player.pause(),
            seek: (pos) => player.seek(pos),
            setRate: (rate) => player.setRate(rate),
          ),
        );

        final reconciler = GuestPlaybackReconciler(
          adapter: adapter,
          clockSync: clockSync,
          socketService: socketService,
          roomId: 'room-1',
          viewerId: 'viewer-1',
        );

        reconciler.updateRoomSnapshot({
          'epoch': 1,
          'revision': 1,
          'mediaVersion': 'mv-1',
          'streamVersion': 'sv-1',
          'waitingForReady': true,
          'readiness': {'version': 5},
          'state': {'paused': true, 'rate': 1.0},
        });

        async.flushMicrotasks();

        expect(socketService.requests, hasLength(1));
        expect(socketService.requests.first['path'], '/api/watch/rooms/room-1/ready');
        final body = socketService.requests.first['body'] as Map<String, dynamic>;
        expect(body['viewerId'], 'viewer-1');
        expect(body['mediaVersion'], 'mv-1');
        expect(body['ready'], true);
        expect(body['readinessVersion'], 5);

        reconciler.dispose();
      });
    });

    test('holds playback during start countdown until startAt', () {
      fakeAsync((async) {
        final clockSync = ClockSync();
        _seedClock(clockSync);

        final socketService = _TestSocketService(clockSync: clockSync);
        final player = _SyncPlayer(hasRenderedFrame: true, playing: false);
        final adapter = PlezyPlayerAdapter(
          player: player,
          copy: _testCopy(),
          commands: PlayerCommands(
            play: () => player.play(),
            pause: () => player.pause(),
            seek: (pos) => player.seek(pos),
            setRate: (rate) => player.setRate(rate),
          ),
        );

        final reconciler = GuestPlaybackReconciler(
          adapter: adapter,
          clockSync: clockSync,
          socketService: socketService,
          roomId: 'room-1',
          viewerId: 'viewer-1',
        );

        final serverNow = clockSync.serverNow;
        reconciler.updateRoomSnapshot({
          'epoch': 1,
          'revision': 1,
          'mediaVersion': 'mv-1',
          'streamVersion': 'sv-1',
          'waitingForReady': false,
          'startAt': serverNow + 500,
          'pauseAt': 0,
          'state': {'paused': false, 'rate': 1.0},
        });

        async.elapse(const Duration(milliseconds: 200));
        expect(player.state.playing, isFalse);

        async.elapse(const Duration(milliseconds: 350));
        async.flushMicrotasks();
        expect(player.state.playing, isTrue);

        reconciler.dispose();
      });
    });

    test('reconciles drift with slew rate between 350ms and 2000ms', () {
      fakeAsync((async) {
        final clockSync = ClockSync();
        _seedClock(clockSync);

        final socketService = _TestSocketService(clockSync: clockSync);
        // Player is at 1000ms, playing
        final player = _SyncPlayer(hasRenderedFrame: true, playing: true, position: const Duration(milliseconds: 1000));
        final rates = <double>[];
        final adapter = PlezyPlayerAdapter(
          player: player,
          copy: _testCopy(),
          commands: PlayerCommands(
            play: () => player.play(),
            pause: () => player.pause(),
            seek: (pos) => player.seek(pos),
            setRate: (rate) async {
              rates.add(rate);
              return player.setRate(rate);
            },
          ),
        );

        final reconciler = GuestPlaybackReconciler(
          adapter: adapter,
          clockSync: clockSync,
          socketService: socketService,
          roomId: 'room-1',
          viewerId: 'viewer-1',
        );

        // Room target is 1600ms (drift = 600ms behind -> slew rate 1.04)
        final serverNow = clockSync.serverNow;
        reconciler.updateRoomSnapshot({
          'epoch': 1,
          'revision': 1,
          'mediaVersion': 'mv-1',
          'streamVersion': 'sv-1',
          'waitingForReady': false,
          'startAt': serverNow - 1600,
          'pauseAt': 0,
          'state': {'paused': false, 'rate': 1.0},
        });

        // Advance 250ms for tick timer
        async.elapse(const Duration(milliseconds: 260));
        async.flushMicrotasks();

        expect(rates, contains(1.04));

        reconciler.dispose();
      });
    });

    test('executes guarded seek when drift exceeds 2000ms', () {
      fakeAsync((async) {
        final clockSync = ClockSync();
        _seedClock(clockSync);

        final socketService = _TestSocketService(clockSync: clockSync);
        final player = _SyncPlayer(hasRenderedFrame: true, playing: true, position: const Duration(milliseconds: 1000));
        final seeks = <Duration>[];
        final adapter = PlezyPlayerAdapter(
          player: player,
          copy: _testCopy(),
          commands: PlayerCommands(
            play: () => player.play(),
            pause: () => player.pause(),
            seek: (pos) async {
              seeks.add(pos);
              return player.seek(pos);
            },
            setRate: (rate) => player.setRate(rate),
          ),
        );

        final reconciler = GuestPlaybackReconciler(
          adapter: adapter,
          clockSync: clockSync,
          socketService: socketService,
          roomId: 'room-1',
          viewerId: 'viewer-1',
        );

        // Room target is 5000ms (drift = 4000ms > 2000ms threshold)
        final serverNow = clockSync.serverNow;
        reconciler.updateRoomSnapshot({
          'epoch': 1,
          'revision': 1,
          'mediaVersion': 'mv-1',
          'streamVersion': 'sv-1',
          'waitingForReady': false,
          'startAt': serverNow - 5000,
          'pauseAt': 0,
          'state': {'paused': false, 'rate': 1.0},
        });

        async.elapse(const Duration(milliseconds: 260));
        async.flushMicrotasks();

        expect(seeks, isNotEmpty);
        expect(seeks.first.inMilliseconds, greaterThanOrEqualTo(4900));

        reconciler.dispose();
      });
    });

    test('observe sends full 12-field payload at 1s periodic cadence', () {
      fakeAsync((async) {
        final clockSync = ClockSync();
        _seedClock(clockSync);

        final socketService = _TestSocketService(clockSync: clockSync);
        final player = _SyncPlayer(
          hasRenderedFrame: true,
          playing: true,
          position: const Duration(milliseconds: 120500),
        );
        final adapter = PlezyPlayerAdapter(
          player: player,
          copy: _testCopy(),
          commands: PlayerCommands(
            play: () => player.play(),
            pause: () => player.pause(),
            seek: (pos) => player.seek(pos),
            setRate: (rate) => player.setRate(rate),
          ),
        );

        final reconciler = GuestPlaybackReconciler(
          adapter: adapter,
          clockSync: clockSync,
          socketService: socketService,
          roomId: 'room-1',
          viewerId: 'viewer-1',
        );

        final serverNow = clockSync.serverNow;
        reconciler.updateRoomSnapshot({
          'epoch': 'epoch-uuid-2',
          'revision': 4,
          'mediaVersion': 'mv-10',
          'streamVersion': 'sv-20',
          'observationEpoch': 'oe-99',
          'waitingForReady': false,
          'startAt': serverNow - 120500,
          'state': {'paused': false, 'rate': 1.0, 'position': 120.5, 'duration': 7200.0},
        });

        // 1s periodic timer tick
        async.elapse(const Duration(milliseconds: 1000));
        async.flushMicrotasks();

        final observeRequests = socketService.requests
            .where((r) => (r['path'] as String).endsWith('/observe'))
            .toList();

        expect(observeRequests, hasLength(1));
        expect(reconciler.epoch, 'epoch-uuid-2');
        final body = observeRequests.first['body'] as Map<String, dynamic>;

        // Verify all 12 fields strictly matching server/playback-tracking.js
        expect(body['viewerId'], 'viewer-1');
        expect(body['epoch'], 'epoch-uuid-2');
        expect(body['mediaVersion'], 'mv-10');
        expect(body['streamVersion'], 'sv-20');
        expect(body['observationEpoch'], 'oe-99');
        expect(body['sequence'], 1);
        expect(body['sampleAt'], isA<double>());
        expect(body['observedAt'], isA<int>());
        expect(body['position'], 120.5); // position in seconds double
        expect(body['rate'], 1.0);
        expect(body['frames'], isA<int>());
        expect(body['frames'] as int, greaterThanOrEqualTo(1));
        expect(body['discontinuity'], 0);
        expect(body['state'], 'playing');

        final prevSampleAt = body['sampleAt'] as double;
        final prevFrames = body['frames'] as int;

        // Advance another 1s for sequence 2
        async.elapse(const Duration(milliseconds: 1000));
        async.flushMicrotasks();

        final updatedObserve = socketService.requests.where((r) => (r['path'] as String).endsWith('/observe')).toList();
        expect(updatedObserve, hasLength(2));
        final secondBody = updatedObserve[1]['body'] as Map<String, dynamic>;

        expect(secondBody['sequence'], 2);
        expect(secondBody['sampleAt'] as double, greaterThan(prevSampleAt));
        expect(secondBody['frames'] as int, greaterThan(prevFrames));
        expect(secondBody['discontinuity'], 0);
        expect(secondBody['state'], 'playing');

        reconciler.dispose();
      });
    });

    test('natural ended transition does not increment discontinuity', () {
      fakeAsync((async) {
        final clockSync = ClockSync();
        _seedClock(clockSync);

        final socketService = _TestSocketService(clockSync: clockSync);
        final completedController = StreamController<bool>.broadcast();
        final player = _SyncPlayer(
          hasRenderedFrame: true,
          playing: true,
          position: const Duration(seconds: 100),
          completedStream: completedController.stream,
        );
        final adapter = PlezyPlayerAdapter(
          player: player,
          copy: _testCopy(),
          commands: PlayerCommands(
            play: () => player.play(),
            pause: () => player.pause(),
            seek: (pos) => player.seek(pos),
            setRate: (rate) => player.setRate(rate),
          ),
        );

        final reconciler = GuestPlaybackReconciler(
          adapter: adapter,
          clockSync: clockSync,
          socketService: socketService,
          roomId: 'room-1',
          viewerId: 'viewer-1',
        );

        final serverNow = clockSync.serverNow;
        reconciler.updateRoomSnapshot({
          'epoch': 1,
          'mediaVersion': 'mv-1',
          'streamVersion': 'sv-1',
          'observationEpoch': 'oe-1',
          'waitingForReady': false,
          'startAt': serverNow - 100000,
          'state': {'paused': false, 'rate': 1.0, 'position': 100.0, 'duration': 7200.0},
        });

        // 1s periodic observe
        async.elapse(const Duration(milliseconds: 1000));
        async.flushMicrotasks();

        final observe1 =
            socketService.requests.where((r) => (r['path'] as String).endsWith('/observe')).last['body']
                as Map<String, dynamic>;
        expect(observe1['state'], 'playing');
        expect(observe1['discontinuity'], 0);

        // Player natural completion: mark completed and emit completed event
        player.setCompleted(true);
        completedController.add(true);
        async.flushMicrotasks();

        final observeEnded =
            socketService.requests.where((r) => (r['path'] as String).endsWith('/observe')).last['body']
                as Map<String, dynamic>;

        expect(observeEnded['state'], 'ended');
        // Critical: discontinuity must remain identical (0) to allow automatic queue advancement
        expect(observeEnded['discontinuity'], 0);

        reconciler.dispose();
        completedController.close();
      });
    });

    test('adopts new observationEpoch from snapshot and resets sequence on 409', () {
      fakeAsync((async) {
        final clockSync = ClockSync();
        _seedClock(clockSync);

        final socketService = _TestSocketService(clockSync: clockSync);
        final player = _SyncPlayer(hasRenderedFrame: true, playing: true, position: const Duration(seconds: 50));
        final adapter = PlezyPlayerAdapter(
          player: player,
          copy: _testCopy(),
          commands: PlayerCommands(
            play: () => player.play(),
            pause: () => player.pause(),
            seek: (pos) => player.seek(pos),
            setRate: (rate) => player.setRate(rate),
          ),
        );

        final reconciler = GuestPlaybackReconciler(
          adapter: adapter,
          clockSync: clockSync,
          socketService: socketService,
          roomId: 'room-1',
          viewerId: 'viewer-1',
        );

        final serverNow = clockSync.serverNow;
        reconciler.updateRoomSnapshot({
          'epoch': 1,
          'mediaVersion': 'mv-1',
          'streamVersion': 'sv-1',
          'observationEpoch': 'epoch-alpha',
          'waitingForReady': false,
          'startAt': serverNow - 50000,
          'state': {'paused': false, 'rate': 1.0, 'position': 50.0, 'duration': 7200.0},
        });

        async.elapse(const Duration(milliseconds: 1000));
        async.flushMicrotasks();

        final obs1 =
            socketService.requests.where((r) => (r['path'] as String).endsWith('/observe')).last['body']
                as Map<String, dynamic>;
        expect(obs1['observationEpoch'], 'epoch-alpha');
        expect(obs1['sequence'], 1);

        // Server returns 409 observation-timeout for next observe
        socketService.onSendRequest = (path, data) {
          if (path.endsWith('/observe')) {
            return const UburoomResponse(id: 2, status: 409, value: {'error': 'observation-timeout'});
          }
          return const UburoomResponse(id: 2, status: 200, value: {'ok': true});
        };

        // Snapshot arrives with rotated observationEpoch
        reconciler.updateRoomSnapshot({
          'epoch': 1,
          'mediaVersion': 'mv-1',
          'streamVersion': 'sv-1',
          'observationEpoch': 'epoch-beta',
          'waitingForReady': false,
          'state': {'paused': false, 'rate': 1.0},
        });

        async.elapse(const Duration(milliseconds: 1000));
        async.flushMicrotasks();

        final obs2 =
            socketService.requests.where((r) => (r['path'] as String).endsWith('/observe')).last['body']
                as Map<String, dynamic>;
        expect(obs2['observationEpoch'], 'epoch-beta');
        expect(obs2['sequence'], 1); // Sequence reset after 409/epoch rotate

        reconciler.dispose();
      });
    });
  });

  group('WatchTogetherProvider Uburoom integration', () {
    test('stores UUID string epoch and sends it in /command', () async {
      final clockSync = ClockSync();
      _seedClock(clockSync);
      final socketService = _TestSocketService(clockSync: clockSync);
      final provider = WatchTogetherProvider(
        socketService: socketService,
        clockSync: clockSync,
        viewerId: 'viewer-uuid-1',
      );
      provider.setUburoomSessionForTest(
        roomId: 'room-uuid-1',
        serverUrl: 'http://localhost:6767',
        token: 'token-64hex',
      );

      final snapshot = {
        'epoch': '3886f4cb-20d4-4a49-a29d-4766e4a2a6d8',
        'revision': 5,
        'mediaVersion': 'mv-test',
        'streamVersion': 'sv-test',
        'observationEpoch': 'oe-test',
        'waitingForReady': false,
        'startAt': clockSync.serverNow,
        'state': {'paused': false, 'rate': 1.0},
      };

      provider.handleUburoomSnapshotForTest(snapshot);
      expect(provider.debugUburoomEpoch, '3886f4cb-20d4-4a49-a29d-4766e4a2a6d8');

      await provider.sendUburoomCommandForTest('media.play');

      final cmdRequests = socketService.requests.where((r) => (r['path'] as String).endsWith('/command')).toList();
      expect(cmdRequests, hasLength(1));
      final body = cmdRequests.first['body'] as Map<String, dynamic>;
      expect(body['epoch'], '3886f4cb-20d4-4a49-a29d-4766e4a2a6d8');
      expect(body['command']['action'], 'media.play');
    });

    test('resolves relative mediaUrl and scopes Authorization header to same-origin uburoom server', () {
      final clockSync = ClockSync();
      _seedClock(clockSync);
      final socketService = _TestSocketService(clockSync: clockSync);
      final provider = WatchTogetherProvider(
        socketService: socketService,
        clockSync: clockSync,
        viewerId: 'viewer-uuid-1',
      );
      provider.setUburoomSessionForTest(
        roomId: 'room-uuid-1',
        serverUrl: 'http://localhost:6767',
        token: 'token-64hex',
      );

      final snapshot = {
        'epoch': '3886f4cb-20d4-4a49-a29d-4766e4a2a6d8',
        'revision': 5,
        'media': {'id': '12345', 'title': 'The Matrix', 'duration': 7200000, 'kind': 'movie'},
        'mediaUrl': '/api/watch/media/grant-abc/start',
        'waitingForReady': false,
        'startAt': clockSync.serverNow,
        'state': {'paused': false, 'rate': 1.0},
      };

      provider.handleUburoomSnapshotForTest(snapshot);

      final choice = provider.state.choice;
      expect(choice, isNotNull);
      final item = choice!.ref.item;
      expect(item, isNotNull);
      expect(item!.raw?['uburoomMediaUrl'], 'http://localhost:6767/api/watch/media/grant-abc/start');
      expect(item!.raw?['uburoomHeaders'], {'Authorization': 'Bearer token-64hex'});
    });

    test('does not attach Authorization header to cross-origin Plex direct delivery URLs', () {
      final clockSync = ClockSync();
      _seedClock(clockSync);
      final socketService = _TestSocketService(clockSync: clockSync);
      final provider = WatchTogetherProvider(
        socketService: socketService,
        clockSync: clockSync,
        viewerId: 'viewer-uuid-1',
      );
      provider.setUburoomSessionForTest(
        roomId: 'room-uuid-1',
        serverUrl: 'http://localhost:6767',
        token: 'token-64hex',
      );

      final directPmsUrl =
          'https://192-168-1-50.abcdef123456.plex.direct:32400/video/:/transcode/universal/start.m3u8?X-Plex-Token=plex-token';
      final snapshot = {
        'epoch': '3886f4cb-20d4-4a49-a29d-4766e4a2a6d8',
        'revision': 5,
        'media': {'id': '12345', 'title': 'The Matrix', 'duration': 7200000, 'kind': 'movie'},
        'mediaUrl': directPmsUrl,
        'directDelivery': true,
        'waitingForReady': false,
        'startAt': clockSync.serverNow,
        'state': {'paused': false, 'rate': 1.0},
      };

      provider.handleUburoomSnapshotForTest(snapshot);

      final choice = provider.state.choice;
      expect(choice, isNotNull);
      final item = choice!.ref.item;
      expect(item, isNotNull);
      expect(item!.raw?['uburoomMediaUrl'], directPmsUrl);
      expect(item!.raw?['uburoomHeaders'], isEmpty);
    });
  });
}
