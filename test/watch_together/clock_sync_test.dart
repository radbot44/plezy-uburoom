import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/watch_together/services/clock_sync.dart';

void main() {
  group('ClockSync', () {
    test('computes accurate offset with symmetric RTT and server processing', () {
      final sync = ClockSync();
      expect(sync.isSynchronized, isFalse);

      // Client sends at t1=1000
      // Server receives at t2=1050 (one-way trip 50ms, client is at server time)
      // Server processes for 10ms
      // Server sends at t3=1060
      // Client receives at t4=1110 (one-way trip 50ms)
      // Net RTT = (1110 - 1000) - 10 = 100ms.
      // Offset = ((1050 - 1000) + (1060 - 1110)) / 2 = (50 - 50) / 2 = 0.
      sync.addSample(
        localSendAt: 1000,
        serverReceivedAt: 1050,
        serverSentAt: 1060,
        serverProcessingMs: 10.0,
        localReceiveAt: 1110,
        clockEpoch: 'epoch-1',
      );
      expect(sync.currentOffsetMs, closeTo(0.0, 0.01));
      expect(sync.rttMs, closeTo(100.0, 0.01));
      expect(sync.isSynchronized, isFalse); // Needs >= 2 samples

      // Add second sample with client clock 500ms behind server
      // Client t1=2000 (real server time 2500)
      // Server t2=2520 (trip 20ms)
      // Server t3=2525 (proc 5ms)
      // Client t4=2045 (trip 20ms)
      // Net RTT = 45 - 5 = 40ms.
      // Offset = ((2520 - 2000) + (2525 - 2045)) / 2 = (520 + 480) / 2 = 500ms.
      sync.addSample(
        localSendAt: 2000,
        serverReceivedAt: 2520,
        serverSentAt: 2525,
        serverProcessingMs: 5.0,
        localReceiveAt: 2045,
        clockEpoch: 'epoch-1',
      );

      expect(sync.isSynchronized, isTrue);
      // Because sample 2 had much lower RTT (40ms vs 100ms), weight heavily favors sample 2.
      expect(sync.currentOffsetMs, greaterThan(300.0));
    });

    test('resets sample history on clockEpoch change', () {
      final sync = ClockSync();
      sync.addSample(
        localSendAt: 1000,
        serverReceivedAt: 2000,
        serverSentAt: 2005,
        serverProcessingMs: 5.0,
        localReceiveAt: 1010,
        clockEpoch: 'epoch-1',
      );
      sync.addSample(
        localSendAt: 2000,
        serverReceivedAt: 3000,
        serverSentAt: 3005,
        serverProcessingMs: 5.0,
        localReceiveAt: 2010,
        clockEpoch: 'epoch-1',
      );
      expect(sync.isSynchronized, isTrue);
      expect(sync.sampleCount, equals(2));

      // Server restarts and reports epoch-2
      sync.addSample(
        localSendAt: 3000,
        serverReceivedAt: 3000,
        serverSentAt: 3005,
        serverProcessingMs: 5.0,
        localReceiveAt: 3010,
        clockEpoch: 'epoch-2',
      );
      expect(sync.clockEpoch, equals('epoch-2'));
      expect(sync.sampleCount, equals(1));
      expect(sync.isSynchronized, isFalse);
    });

    test('toServerTime and toLocalTime bidirectional conversion', () {
      final sync = ClockSync();
      sync.addSample(
        localSendAt: 1000,
        serverReceivedAt: 2000,
        serverSentAt: 2000,
        serverProcessingMs: 0.0,
        localReceiveAt: 1000,
        clockEpoch: 1,
      );
      sync.addSample(
        localSendAt: 2000,
        serverReceivedAt: 3000,
        serverSentAt: 3000,
        serverProcessingMs: 0.0,
        localReceiveAt: 2000,
        clockEpoch: 1,
      );

      expect(sync.currentOffsetMs, closeTo(1000.0, 0.01));
      expect(sync.toServerTime(5000), equals(6000));
      expect(sync.toLocalTime(6000), equals(5000));
    });
  });
}
