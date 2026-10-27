import 'dart:math' as math;

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
  ClockSync({this.maxSamples = 16, this.sampleRetentionMs = 30000});

  final int maxSamples;
  final int sampleRetentionMs;

  final List<ClockSample> _samples = [];
  dynamic _currentEpoch;
  double _filteredOffsetMs = 0.0;
  double _lastRttMs = 0.0;

  bool get isSynchronized => _samples.length >= 2;
  double get currentOffsetMs => _filteredOffsetMs;
  double get rttMs => _lastRttMs;
  dynamic get clockEpoch => _currentEpoch;
  int get sampleCount => _samples.length;

  /// Current estimated server time in milliseconds since Unix epoch.
  int get serverNow => DateTime.now().millisecondsSinceEpoch + _filteredOffsetMs.round();

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
    // If the server reported an epoch restart or change, invalidate earlier samples.
    if (_currentEpoch != null && _currentEpoch != clockEpoch) {
      reset();
    }
    _currentEpoch = clockEpoch;

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
  }

  void _pruneAndFilter(int now) {
    _samples.removeWhere((s) => now - s.localReceiveAt > sampleRetentionMs);
    while (_samples.length > maxSamples) {
      _samples.removeAt(0);
    }
    if (_samples.isEmpty) {
      _filteredOffsetMs = 0.0;
      return;
    }

    // Find the minimum RTT among recent samples.
    double minRtt = double.infinity;
    for (final s in _samples) {
      if (s.rttMs < minRtt) minRtt = s.rttMs;
    }

    // Keep samples within a tight window of the lowest RTT (e.g. minRtt + 20ms)
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
  }
}
