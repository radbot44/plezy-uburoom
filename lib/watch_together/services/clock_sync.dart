import 'dart:math' as math;
import 'package:clock/clock.dart';

/// Four-timestamp exchange fenced against resets while it is in flight.
class ClockRequest {
  const ClockRequest(this.sent, this.revision);
  final int sent;
  final int revision;
}

class _Evidence {
  _Evidence(this.at, this.rtt, this.offset, {this.suspect = false});
  final int at;
  final double rtt, offset;
  bool suspect;
}

/// Port of shared/sync/timing.mjs clock (protocol v2). The mapping uses
/// monotonic time; wall time is only used to detect clock discontinuities.
class ClockSync {
  ClockSync({int Function()? nowMs, this.monotonicNowMs})
    : _nowMs = nowMs ?? (() => clock.now().millisecondsSinceEpoch);
  final int Function() _nowMs;
  final int Function()? monotonicNowMs;
  final Stopwatch _watch = clock.stopwatch()..start();
  int get monotonicNow => monotonicNowMs?.call() ?? _watch.elapsedMilliseconds;
  final List<_Evidence> _samples = [], _delays = [], _delayed = [];
  double? _mapping, _desired;
  int? _adjustedAt, _lastGood, _lastTick, _lastWall, _lastSent;
  String? _epoch;
  bool _uncertain = false;
  int _revision = 0, _acquired = 0;
  int accepted = 0, rejected = 0;
  String reason = 'startup';
  int get revision => _revision;
  String? get clockEpoch => _epoch;
  int get sampleCount => _samples.length;
  int? get lastSampleReceivedAt => _lastGood == null ? null : _nowMs() - (monotonicNow - _lastGood!);

  void reset([String why = 'disconnect']) {
    _samples.clear();
    _delays.clear();
    _delayed.clear();
    _mapping = _desired = null;
    _adjustedAt = _lastGood = _lastTick = _lastWall = _lastSent = null;
    _epoch = null;
    _uncertain = false;
    _revision++;
    reason = why;
  }

  int _tick() {
    final now = monotonicNow, wall = _nowMs();
    if (_lastTick != null &&
        (now < _lastTick! || now - _lastTick! > 5000 || (wall - _lastWall! - (now - _lastTick!)).abs() > 250)) {
      reset('discontinuity');
    }
    _lastTick = now;
    _lastWall = wall;
    if (_mapping != null) {
      final limit = math.max(0, now - _adjustedAt!) * 0.002;
      _mapping = _mapping! + (_desired! - _mapping!).clamp(-limit, limit);
      _adjustedAt = now;
    }
    return now;
  }

  ClockRequest begin() => ClockRequest(_tick(), _revision);

  bool add(ClockRequest request, Map<String, dynamic> timing) {
    final received = _tick(), duration = received - request.sent;
    final t2 = timing['serverReceivedAt'], t3 = timing['serverSentAt'];
    final processing = timing['serverProcessingMs'], epoch = timing['clockEpoch'];
    bool reject(String why) {
      rejected++;
      reason = why;
      return false;
    }

    if (request.revision != _revision) return reject('discontinuity');
    if (_lastSent != null && request.sent <= _lastSent!) return reject('invalid');
    _lastSent = request.sent;
    if (t2 is! num ||
        t3 is! num ||
        processing is! num ||
        !t2.isFinite ||
        !t3.isFinite ||
        !processing.isFinite ||
        duration < 0 ||
        processing < 0 ||
        t3 < t2 ||
        (t3 - t2 - processing).abs() > 5 ||
        processing > duration + 5 ||
        epoch is! String ||
        epoch.isEmpty) {
      return reject('invalid');
    }
    final rtt = math.max(0.0, duration - processing.toDouble());
    if (_epoch != null && epoch != _epoch) {
      reset('server-change');
      _lastTick = received;
      _lastWall = _nowMs();
      _lastSent = request.sent;
    }
    _epoch = epoch;
    final offset = (t2 + t3 - request.sent - received) / 2;
    final evidence = _Evidence(received, rtt, offset);
    _delays.add(evidence);
    _delays.removeWhere((s) => received - s.at > 30000);
    _trim(_delays);
    void confirm() {
      if (_mapping != null && (offset - _mapping!).abs() <= rtt / 2 + 2) _lastGood = received;
    }

    if (rtt > 1500) {
      confirm();
      return reject('delay');
    }
    _samples.removeWhere((s) => received - s.at > 30000);
    final best = _best(received);
    if (best != null && rtt > best.rtt + math.max(20, best.rtt * 0.5)) {
      _delayed.add(evidence);
      if (_delayed.length > 3) _delayed.removeAt(0);
      if (_delayed.length < 3 ||
          !_delayed.every((s) => (s.rtt - rtt).abs() <= math.max(20, rtt * 0.2) && (s.offset - offset).abs() <= 20)) {
        confirm();
        return reject('jitter');
      }
      _samples.clear();
      for (final s in _delays) {
        s.suspect = !identical(s, evidence);
      }
    }
    _delayed.clear();
    if (_mapping != null && (offset - _mapping!).abs() > math.max(250, rtt / 2 + (best?.rtt ?? 0) / 2 + 10)) {
      _uncertain = true;
      evidence.suspect = true;
      _samples.add(_Evidence(received, rtt, offset, suspect: true));
      _trim(_samples);
      final recent = _samples.skip(math.max(0, _samples.length - 3));
      if (recent.length < 3 || !recent.every((s) => s.suspect && (s.offset - offset).abs() < 10)) {
        return reject('outlier');
      }
      _samples.clear();
      _mapping = null;
      _revision++;
      for (final s in _delays) {
        s.suspect = !identical(s, evidence);
      }
    }
    _samples.add(_Evidence(received, rtt, offset));
    _trim(_samples);
    final reliable = _samples.where((s) => !s.suspect).toList()
      ..sort((a, b) {
        final order = a.rtt.compareTo(b.rtt);
        return order != 0 ? order : b.at.compareTo(a.at);
      });
    _desired = reliable.first.offset;
    if (_mapping == null) {
      _mapping = _desired;
      _acquired = 0;
    } else if (_acquired < 8) {
      final range = reliable.first.rtt / 2 + 2;
      _mapping = _mapping!.clamp(_desired! - range, _desired! + range);
    }
    _acquired++;
    _adjustedAt = received;
    _lastGood = received;
    _uncertain = false;
    accepted++;
    reason = 'accepted';
    return true;
  }

  static void _trim(List<_Evidence> samples) {
    if (samples.length > 32) samples.removeRange(0, samples.length - 32);
  }

  _Evidence? _best(int now) {
    _Evidence? best;
    for (final s in _samples) {
      if (!s.suspect && now - s.at <= 30000 && (best == null || s.rtt < best.rtt)) best = s;
    }
    return best;
  }

  ({bool valid, double uncertainty, double stability, double? rtt, double? minRtt}) read() {
    final now = _tick(), best = _best(_lastTick!);
    double upper = double.infinity, lower = 0;
    double? lastRtt;
    void bound(_Evidence s) {
      final width = s.rtt / 2 + 2 + (now - s.at) * 0.0001;
      final distance = (s.offset - _mapping!).abs();
      upper = math.min(upper, distance + width);
      lower = math.max(lower, distance - width);
    }

    if (best != null && _mapping != null) bound(best);
    for (final s in _delays) {
      if (now - s.at <= 30000) {
        lastRtt = s.rtt;
        if (_mapping != null && !s.suspect) bound(s);
      }
    }
    final uncertainty = math.max(upper, lower);
    final valid = _mapping != null && best != null && !_uncertain && uncertainty <= 1000;
    final excess = valid && lastRtt != null ? math.max(0, lastRtt - best.rtt) : 0;
    return (
      valid: valid,
      uncertainty: valid ? uncertainty : double.infinity,
      stability: valid
          ? math.min(25, best.rtt / 2) +
                2 +
                excess / 2 +
                (_desired! - _mapping!).abs() +
                (now - best.at) * 0.0001 +
                math.max(0, lower - upper)
          : double.infinity,
      rtt: lastRtt,
      minRtt: best?.rtt,
    );
  }

  bool get isSynchronized => read().valid;
  double get currentOffsetMs {
    read();
    return _mapping == null ? 0 : monotonicNow + _mapping! - _nowMs();
  }

  double get rttMs => read().rtt ?? 0;
  double? get minRttMs => read().minRtt;
  double get uncertaintyMs => read().uncertainty;
  double get stabilityMs => read().stability;
  int get serverNow {
    read();
    return _mapping == null ? _nowMs() : (monotonicNow + _mapping!).round();
  }

  int toServerTime(int localEpochMs) => localEpochMs + currentOffsetMs.round();
  int toLocalTime(int serverEpochMs) => serverEpochMs - currentOffsetMs.round();
  int measurementFreshnessMs([int? wallNow]) {
    _tick();
    return _lastGood == null ? 0 : math.max(0, monotonicNow - _lastGood!);
  }
}
