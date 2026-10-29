import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/watch_together/services/clock_sync.dart';

void main() {
  group('ClockSync', () {
    test('computes accurate offset with symmetric RTT and server processing', () {
      final sync = ClockSync();
      expect(sync.isSynchronized, isFalse);

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

      sync.addSample(
        localSendAt: 2000,
        serverReceivedAt: 2520,
        serverSentAt: 2525,
        serverProcessingMs: 5.0,
        localReceiveAt: 2045,
        clockEpoch: 'epoch-1',
      );

      expect(sync.isSynchronized, isTrue);
      expect(sync.currentOffsetMs, greaterThan(300.0));
      expect(sync.uncertaintyMs, greaterThanOrEqualTo(20.0));
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

    test('detects local wall-clock discontinuity and resets stale samples', () {
      int monoNow = 1000;
      final sync = ClockSync(monotonicNowMs: () => monoNow);

      sync.addSample(
        localSendAt: 1000,
        serverReceivedAt: 2000,
        serverSentAt: 2005,
        serverProcessingMs: 5.0,
        localReceiveAt: 1010,
        clockEpoch: 'epoch-1',
      );
      monoNow = 2000;
      sync.addSample(
        localSendAt: 2000,
        serverReceivedAt: 3000,
        serverSentAt: 3005,
        serverProcessingMs: 5.0,
        localReceiveAt: 2010,
        clockEpoch: 'epoch-1',
      );
      expect(sync.isSynchronized, isTrue);
      expect(sync.sampleCount, 2);

      // Monotonic clock advances 1000ms, but OS wall clock jumped forward by +5000ms (total +6000ms)
      monoNow = 3000;
      sync.addSample(
        localSendAt: 8000,
        serverReceivedAt: 4000,
        serverSentAt: 4005,
        serverProcessingMs: 5.0,
        localReceiveAt: 8010,
        clockEpoch: 'epoch-1',
      );

      expect(sync.sampleCount, 1);
      expect(sync.isSynchronized, isFalse);
      expect(sync.currentOffsetMs, closeTo(-4002.5, 0.1));
    });

    test('toServerTime, toLocalTime, and measurementFreshnessMs', () {
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
      expect(sync.measurementFreshnessMs(2350), equals(350));
    });
  });
}
