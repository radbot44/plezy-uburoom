import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/watch_together/services/clock_sync.dart';
import 'package:plezy/watch_together/services/uburoom_socket_service.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeWebSocketSink implements WebSocketSink {
  final List<String> sent = [];
  final Completer<void> _done = Completer<void>();

  @override
  Future<dynamic> get done => _done.future;

  @override
  void add(dynamic data) {
    sent.add(data.toString());
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream stream) => Future.value();

  @override
  Future close([int? closeCode, String? closeReason]) {
    if (!_done.isCompleted) _done.complete();
    return _done.future;
  }
}

class FakeWebSocketChannel extends StreamChannelMixin<dynamic> implements WebSocketChannel {
  FakeWebSocketChannel() {
    sink = FakeWebSocketSink();
  }

  // ignore: close_sinks
  final StreamController<dynamic> controller = StreamController<dynamic>();
  @override
  // ignore: close_sinks
  late final FakeWebSocketSink sink;

  @override
  Stream<dynamic> get stream => controller.stream;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready => Future.value();
}

void main() {
  group('UburoomSocketService', () {
    late FakeWebSocketChannel fakeChannel;
    late ClockSync clockSync;
    late UburoomSocketService service;

    setUp(() {
      fakeChannel = FakeWebSocketChannel();
      clockSync = ClockSync();
      service = UburoomSocketService(clockSync: clockSync, channelFactory: (uri, origin) async => fakeChannel);
    });

    tearDown(() {
      service.dispose();
    });

    test('connects, authenticates, and transitions to connected', () async {
      final connectFuture = service.connect(
        serverUrl: 'https://uburoom.example.com',
        token: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );

      // Verify auth frame sent
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(fakeChannel.sink.sent.length, greaterThanOrEqualTo(1));
      final authMsg = jsonDecode(fakeChannel.sink.sent.first) as Map<String, dynamic>;
      expect(authMsg['type'], equals('hello'));
      expect(authMsg['protocol'], equals(uburoomProtocolVersion));
      expect(authMsg['token'], equals('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'));

      // Server welcomes the connection
      fakeChannel.controller.add(jsonEncode({'type': 'welcome', 'protocol': 2, 'connectionId': 42}));
      await connectFuture;

      expect(service.isConnected, isTrue);
      expect(service.state, equals(UburoomConnectionState.connected));
    });

    test('handles clock exchange and feeds ClockSync', () async {
      final connectFuture = service.connect(
        serverUrl: 'https://uburoom.example.com',
        token: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      fakeChannel.controller.add(jsonEncode({'type': 'welcome', 'protocol': 2, 'connectionId': 1}));
      await connectFuture;

      // Clock loop sends clock frame
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final clockSent = fakeChannel.sink.sent
          .map((s) => jsonDecode(s) as Map<String, dynamic>)
          .firstWhere((m) => m['type'] == 'clock');
      final clockId = clockSent['id'] as int;

      fakeChannel.controller.add(
        jsonEncode({
          'type': 'clock',
          'id': clockId,
          'serverNow': 1729000000000,
          'timing': {
            'serverReceivedAt': 1729000000000,
            'serverSentAt': 1729000000005,
            'serverProcessingMs': 5.0,
            'clockEpoch': 'epoch-1',
          },
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(clockSync.sampleCount, equals(1));
      expect(clockSync.clockEpoch, equals('epoch-1'));
    });

    Future<void> connected() async {
      final connectFuture = service.connect(
        serverUrl: 'https://uburoom.example.com',
        token: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      fakeChannel.controller.add(jsonEncode({'type': 'welcome', 'protocol': 2, 'connectionId': 1}));
      await connectFuture;
    }

    Map<String, dynamic> lastSent(String type) =>
        fakeChannel.sink.sent.map((s) => jsonDecode(s) as Map<String, dynamic>).lastWhere((m) => m['type'] == type);

    test('a call resolves with its ack, and a refusal with its status and message', () async {
      await connected();

      final listed = service.call('rooms.list');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      var sent = lastSent('call');
      expect(sent['op'], equals('rooms.list'));
      fakeChannel.controller.add(
        jsonEncode({
          'type': 'ack',
          'id': sent['id'],
          'value': {'rooms': []},
        }),
      );
      final res = await listed;
      expect(res.isSuccess, isTrue);
      expect(res.value, equals({'rooms': []}));

      final queued = service.call('room.queue.command', roomId: 'room-1', args: {'action': 'clear'});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      sent = lastSent('call');
      expect(sent['roomId'], equals('room-1'));
      expect(sent['args'], equals({'action': 'clear'}));
      fakeChannel.controller.add(
        jsonEncode({'type': 'error', 'id': sent['id'], 'code': 'refused', 'status': 403, 'message': 'Not allowed'}),
      );
      final refused = await queued;
      expect(refused.isSuccess, isFalse);
      expect(refused.status, equals(403));
      expect(refused.error, equals('Not allowed'));
    });

    test('join answers with the merged lanes; pushed lanes are shown only once they describe the same video', () async {
      await connected();
      final pushes = <UburoomRoomStatePush>[];
      final kicked = <String>[];
      final stateSub = service.roomStateStream.listen(pushes.add);
      final kickSub = service.roomKickedStream.listen(kicked.add);

      final joining = service.join('room-1', 'viewer-1', quality: 'direct', delivery: 'auto');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final sent = lastSent('join');
      expect(sent['roomId'], equals('room-1'));
      expect(sent['viewerId'], equals('viewer-1'));
      expect(sent['preferences'], equals({'quality': 'direct', 'delivery': 'auto'}));
      fakeChannel.controller.add(
        jsonEncode({
          'type': 'ack',
          'id': sent['id'],
          'value': {
            'roomId': 'room-1',
            'viewerId': 'viewer-1',
            'room': {
              'version': 4,
              'state': {
                'id': 'room-1',
                'epoch': 'e1',
                'mediaVersion': 'm1',
                'state': {'paused': true, 'position': 3},
              },
            },
            'viewer': {
              'version': 1,
              'state': {
                'mediaVersion': 'm1',
                'streamVersion': 's1',
                'mediaUrl': '/api/watch/media/g1/start',
                'volume': 30,
                'muted': false,
              },
            },
          },
        }),
      );
      final joined = await joining;
      expect(joined.isSuccess, isTrue);
      expect(joined.value['epoch'], equals('e1'));
      expect(joined.value['mediaUrl'], equals('/api/watch/media/g1/start'));
      expect(joined.value['state'], equals({'paused': true, 'position': 3, 'volume': 30, 'muted': false}));

      // The room moves to another video: its lane alone is not shown with the old stream.
      fakeChannel.controller.add(
        jsonEncode({
          'type': 'room',
          'roomId': 'room-1',
          'viewerId': 'viewer-1',
          'version': 5,
          'state': {
            'id': 'room-1',
            'epoch': 'e1',
            'mediaVersion': 'm2',
            'state': {'paused': true, 'position': 0},
          },
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(pushes, isEmpty);
      fakeChannel.controller.add(
        jsonEncode({
          'type': 'viewer',
          'roomId': 'room-1',
          'viewerId': 'viewer-1',
          'version': 2,
          'state': {'mediaVersion': 'm2', 'streamVersion': 's2', 'volume': 30, 'muted': false},
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(pushes, hasLength(1));
      expect(pushes.single.isSuccess, isTrue);
      expect(pushes.single.value['mediaVersion'], equals('m2'));
      expect(pushes.single.value['streamVersion'], equals('s2'));
      expect(pushes.single.value.containsKey('mediaUrl'), isFalse, reason: 'a lane replaces that lane whole');

      // An older lane, or one for another tab, is dropped.
      fakeChannel.controller.add(
        jsonEncode({
          'type': 'room',
          'roomId': 'room-1',
          'viewerId': 'viewer-1',
          'version': 3,
          'state': {'mediaVersion': 'm2', 'epoch': 'stale'},
        }),
      );
      fakeChannel.controller.add(
        jsonEncode({
          'type': 'room',
          'roomId': 'room-1',
          'viewerId': 'another-tab',
          'version': 9,
          'state': {'mediaVersion': 'm2', 'epoch': 'foreign'},
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(pushes, hasLength(1));

      // The room lets this tab go: a refusal that says to join again.
      fakeChannel.controller.add(
        jsonEncode({
          'type': 'error',
          'code': 'room',
          'roomId': 'room-1',
          'viewerId': 'viewer-1',
          'status': 409,
          'message': 'You are no longer in this room; join again',
          'rejoin': true,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(pushes, hasLength(2));
      expect(pushes.last.isSuccess, isFalse);
      expect(pushes.last.status, equals(409));
      expect(pushes.last.rejoin, isTrue);
      expect(pushes.last.error, equals('You are no longer in this room; join again'));

      fakeChannel.controller.add(
        jsonEncode({'type': 'error', 'code': 'removed', 'roomId': 'room-1', 'status': 403, 'message': 'Removed'}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(kicked, equals(['room-1']));

      await stateSub.cancel();
      await kickSub.cancel();
    });

    test('sendSyncQuality emits telemetry message', () async {
      final connectFuture = service.connect(
        serverUrl: 'https://uburoom.example.com',
        token: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      fakeChannel.controller.add(jsonEncode({'type': 'welcome', 'protocol': 2, 'connectionId': 1}));
      await connectFuture;

      service.sendSyncQuality(
        roomId: 'room-1',
        viewerId: 'viewer-1',
        mediaVersion: 'mv-1',
        streamVersion: 'sv-1',
        status: 'playing',
        score: 0.98,
        confidence: 'confident',
        measurementFreshnessMs: 120,
      );

      final msg = fakeChannel.sink.sent
          .map((s) => jsonDecode(s) as Map<String, dynamic>)
          .firstWhere((m) => m['type'] == 'quality');
      expect(msg['roomId'], equals('room-1'));
      expect(msg['score'], equals(0.98));
      expect(msg['confidence'], equals('confident'));
      expect(msg['status'], equals('playing'));
    });

    test('fails immediately on a refusal during the handshake and disconnect cleans up without reconnect', () async {
      final connectFuture = service.connect(
        serverUrl: 'https://uburoom.example.com',
        token: 'invalid-token-1234567890abcdef1234567890abcdef1234567890abcdef12345678',
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(service.state, equals(UburoomConnectionState.authenticating));

      // The server is full
      fakeChannel.controller.add(
        jsonEncode({
          'type': 'error',
          'code': 'full',
          'status': 429,
          'message': 'Server full; try again when someone leaves',
        }),
      );

      // Must complete immediately instead of waiting for 5-second auth timeout
      await connectFuture.timeout(const Duration(milliseconds: 500));

      expect(service.state, equals(UburoomConnectionState.reconnecting));
      expect(service.hasActiveReconnectTimer, isTrue);

      // Clean disconnect cancels reconnect timer and transitions to disconnected
      await service.disconnect();
      expect(service.state, equals(UburoomConnectionState.disconnected));
      expect(service.isExplicitlyClosed, isTrue);
      expect(service.hasActiveReconnectTimer, isFalse);

      // Ensure no further reconnect attempts are scheduled
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(service.state, equals(UburoomConnectionState.disconnected));
      expect(service.hasActiveReconnectTimer, isFalse);
    });

    test('a protocol mismatch is reported in the server\'s words and is not retried', () async {
      final connectFuture = service.connect(
        serverUrl: 'https://uburoom.example.com',
        token: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      final failed = expectLater(
        connectFuture,
        throwsA(
          isA<UburoomProtocolException>().having(
            (e) => e.message,
            'message',
            'This server speaks room protocol 3; update this app to connect.',
          ),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(service.state, equals(UburoomConnectionState.authenticating));
      fakeChannel.controller.add(
        jsonEncode({
          'type': 'error',
          'code': 'protocol',
          'status': 426,
          'message': 'This server speaks room protocol 3; update this app to connect.',
          'supported': [3],
        }),
      );
      await failed;

      expect(service.state, equals(UburoomConnectionState.disconnected));
      expect(service.protocolError, isNotNull);
      expect(service.hasActiveReconnectTimer, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(service.hasActiveReconnectTimer, isFalse);
    });
  });
}
