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
      expect(authMsg['type'], equals('auth'));
      expect(authMsg['token'], equals('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'));

      // Server sends auth-ok
      fakeChannel.controller.add(jsonEncode({'type': 'auth-ok', 'connectionId': 42}));
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
      fakeChannel.controller.add(jsonEncode({'type': 'auth-ok', 'connectionId': 1}));
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

    test('sendRequest dispatches request and resolves matching response', () async {
      final connectFuture = service.connect(
        serverUrl: 'https://uburoom.example.com',
        token: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      fakeChannel.controller.add(jsonEncode({'type': 'auth-ok', 'connectionId': 1}));
      await connectFuture;

      final reqFuture = service.sendRequest('/api/watch/rooms', {'test': 123});
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final reqSent = fakeChannel.sink.sent
          .map((s) => jsonDecode(s) as Map<String, dynamic>)
          .firstWhere((m) => m['type'] == 'request' && m['path'] == '/api/watch/rooms');
      final reqId = reqSent['id'] as int;
      expect(reqSent['data'], equals({'test': 123}));

      // Simulate server response
      fakeChannel.controller.add(
        jsonEncode({
          'type': 'response',
          'id': reqId,
          'status': 200,
          'value': {'rooms': []},
        }),
      );

      final res = await reqFuture;
      expect(res.status, equals(200));
      expect(res.value, equals({'rooms': []}));
    });

    test('sendSyncQuality emits telemetry message', () async {
      final connectFuture = service.connect(
        serverUrl: 'https://uburoom.example.com',
        token: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      fakeChannel.controller.add(jsonEncode({'type': 'auth-ok', 'connectionId': 1}));
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
          .firstWhere((m) => m['type'] == 'sync-quality');
      expect(msg['roomId'], equals('room-1'));
      expect(msg['score'], equals(0.98));
      expect(msg['confidence'], equals('confident'));
      expect(msg['status'], equals('playing'));
    });
  });
}
