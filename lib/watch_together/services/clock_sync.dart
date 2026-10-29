import 'dart:math' as math;

import 'package:clock/clock.dart';

/// A single NTP-filtered clock exchange sample with an uburoom server.
class ClockSample {
  ClockSample({
    required this.localSendAt,
    required this.serverReceivedAt,
    required this.serverSentAt,
    required this.serverProcessingMs,
    required this.localReceiveAt,
    required this.clockEpoch,
  });

  final int localSendAt;
  final int serverReceivedAt;
  final int serverSentAt;
  final double serverProcessingMs;
  final int localReceiveAt;
  final dynamic clockEpoch;

  /// Round-trip time excluding server processing time.
  double get rttMs {
    final total = (localReceiveAt - localSendAt).toDouble();
    final net = total - serverProcessingMs;
    return net < 0 ? 0.0 : net;
  }

  /// Estimated offset between server and client clock:
  /// offset = ((t2 - t1) + (t3 - t4)) / 2
  double get offsetMs {
    return ((serverReceivedAt - localSendAt) + (serverSentAt - localReceiveAt)) / 2.0;
  }
}

/// NTP-filtered clock synchronizer tracking uburoom server time.
class ClockSync {
  ClockSync({
    this.maxSamples = 16,
    this.sampleRetentionMs = 30000,
    this.discontinuityThresholdMs = 1000,
    int Function()? nowMs,
    this.monotonicNowMs,
  }) : _nowMs = nowMs ?? _defaultNowMs;

  static int _defaultNowMs() => clock.now().millisecondsSinceEpoch;

  final int maxSamples;
  final int sampleRetentionMs;
  final int discontinuityThresholdMs;
  final int Function() _nowMs;
  final int Function()? monotonicNowMs;
  final Stopwatch _monotonicSw = Stopwatch()..start();

  final List<ClockSample> _samples = [];
  dynamic _currentEpoch;
  double _filteredOffsetMs = 0.0;
  double _lastRttMs = 0.0;
  double _uncertaintyMs = 50.0;
  int? _lastWallReceiveAt;
  int? _lastMonotonicReceiveAt;

  bool get isSynchronized => _samples.length >= 2;
  double get currentOffsetMs => _filteredOffsetMs;
  double get rttMs => _lastRttMs;
  double get uncertaintyMs => _uncertaintyMs;
  dynamic get clockEpoch => _currentEpoch;
  int get sampleCount => _samples.length;
  int? get lastSampleReceivedAt => _lastWallReceiveAt;

  /// Age in milliseconds of the most recent clock sample relative to [nowMs].
  int measurementFreshnessMs([int? nowMs]) {
    final last = _lastWallReceiveAt;
    if (last == null) return 0;
    final current = nowMs ?? _nowMs();
    return math.max(0, current - last);
  }

  /// Current estimated server time in milliseconds since Unix epoch.
  int get serverNow => _nowMs() + _filteredOffsetMs.round();

  /// Converts a local timestamp in epoch milliseconds to server time.
  int toServerTime(int localEpochMs) => localEpochMs + _filteredOffsetMs.round();

  /// Converts a server timestamp in epoch milliseconds to local time.
  int toLocalTime(int serverEpochMs) => serverEpochMs - _filteredOffsetMs.round();

  /// Adds a new clock exchange sample and recalculates the filtered offset.
  void addSample({
    required int localSendAt,
    required int serverReceivedAt,
    required int serverSentAt,
    required double serverProcessingMs,
    required int localReceiveAt,
    required dynamic clockEpoch,
  }) {
    final currentMono = monotonicNowMs != null ? monotonicNowMs!() : _monotonicSw.elapsedMilliseconds;

    // If the server reported an epoch restart or change, invalidate earlier samples.
    if (_currentEpoch != null && _currentEpoch != clockEpoch) {
      reset();
    } else if (_lastWallReceiveAt != null && _lastMonotonicReceiveAt != null) {
      // Detect local OS wall-clock jump using monotonic clock reference.
      final wallDelta = localReceiveAt - _lastWallReceiveAt!;
      final monoDelta = currentMono - _lastMonotonicReceiveAt!;
      if ((wallDelta - monoDelta).abs() > discontinuityThresholdMs) {
        reset();
      }
    } else if (_samples.isNotEmpty) {
      // Also detect extreme offset step (>2000ms) after already synchronized on low-RTT samples.
      final candidateOffset = ((serverReceivedAt - localSendAt) + (serverSentAt - localReceiveAt)) / 2.0;
      final candidateRtt = math.max(0.0, (localReceiveAt - localSendAt).toDouble() - serverProcessingMs);
      if (isSynchronized &&
          candidateRtt <= (_lastRttMs + 100.0) &&
          (candidateOffset - _filteredOffsetMs).abs() > 2000.0) {
        reset();
      }
    }

    _currentEpoch = clockEpoch;
    _lastWallReceiveAt = localReceiveAt;
    _lastMonotonicReceiveAt = currentMono;

    final sample = ClockSample(
      localSendAt: localSendAt,
      serverReceivedAt: serverReceivedAt,
      serverSentAt: serverSentAt,
      serverProcessingMs: serverProcessingMs,
      localReceiveAt: localReceiveAt,
      clockEpoch: clockEpoch,
    );

    _samples.add(sample);
    _lastRttMs = sample.rttMs;
    _pruneAndFilter(localReceiveAt);
  }

  void reset() {
    _samples.clear();
    _currentEpoch = null;
    _filteredOffsetMs = 0.0;
    _lastRttMs = 0.0;
    _uncertaintyMs = 50.0;
    _lastWallReceiveAt = null;
    _lastMonotonicReceiveAt = null;
  }

  void _pruneAndFilter(int now) {
    _samples.removeWhere((s) => now - s.localReceiveAt > sampleRetentionMs);
    while (_samples.length > maxSamples) {
      _samples.removeAt(0);
    }
    if (_samples.isEmpty) {
      _filteredOffsetMs = 0.0;
      _uncertaintyMs = 50.0;
      return;
    }

    // Find the minimum RTT among recent samples.
    double minRtt = double.infinity;
    for (final s in _samples) {
      if (s.rttMs < minRtt) minRtt = s.rttMs;
    }

    // Keep samples within a tight window of the lowest RTT (minRtt + 25ms)
    // to filter out bufferbloat / queueing delay jitter.
    final lowJitterThreshold = minRtt + 25.0;
    final lowJitterSamples = _samples.where((s) => s.rttMs <= lowJitterThreshold).toList();

    // Compute weighted average: samples with lower RTT get exponentially higher weight.
    double totalWeight = 0.0;
    double weightedOffsetSum = 0.0;

    for (final s in lowJitterSamples) {
      final weight = 1.0 / math.max(1.0, s.rttMs);
      weightedOffsetSum += s.offsetMs * weight;
      totalWeight += weight;
    }

    if (totalWeight > 0) {
      _filteredOffsetMs = weightedOffsetSum / totalWeight;
    } else {
      _filteredOffsetMs = _samples.last.offsetMs;
    }

    // Compute clock uncertainty from half minimum RTT plus offset dispersion.
    double maxDeviation = 0.0;
    for (final s in lowJitterSamples) {
      final dev = (s.offsetMs - _filteredOffsetMs).abs();
      if (dev > maxDeviation) maxDeviation = dev;
    }
    _uncertaintyMs = (minRtt * 0.5) + maxDeviation;
  }
}
