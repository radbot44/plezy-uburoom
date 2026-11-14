import 'dart:math' as math;

/// Faithful port of timing.mjs correction(): target-minus-position seconds.
/// Constants are shared with the web algorithm; native passthrough disables rate
/// correction because the receiver owns its audio clock.
class DriftCorrection {
  int? _sinceAt, _sinceSign, _last, _settleUntil, _checkpointAt;
  String? _key;
  int _direction = 0, _quietUntil = 0, _failures = 0;
  double? _estimate, _checkpointMagnitude;
  double _rate = 1;
  void _rest() {
    _sinceAt = _sinceSign = _checkpointAt = null;
    _checkpointMagnitude = null;
    _direction = 0;
    _rate = 1;
  }

  void reset() {
    _rest();
    _last = _settleUntil = null;
    _key = null;
    _estimate = null;
    _quietUntil = _failures = 0;
  }

  double update({
    required int now,
    required double error,
    required bool eligible,
    required String context,
    double uncertaintyMs = 0,
    double? stabilityMs,
    double frameSeconds = 0,
  }) {
    stabilityMs ??= uncertaintyMs;
    if (_key != context) reset();
    final gap = _last == null ? 0 : now - _last!;
    if (gap < 0 || gap > 1500) {
      _rest();
      _estimate = null;
    }
    _key = context;
    _last = now;
    if (!eligible ||
        !error.isFinite ||
        !uncertaintyMs.isFinite ||
        uncertaintyMs < 0 ||
        uncertaintyMs > 250 ||
        !stabilityMs.isFinite ||
        stabilityMs < 0 ||
        stabilityMs > 100 ||
        error.abs() > 0.65 ||
        error == 0) {
      _rest();
      _estimate = null;
      return 1;
    }
    if (_estimate == null) {
      _estimate = error;
    } else {
      final predicted = _estimate! - (_rate - 1) * (gap / 1000);
      _estimate = (error - predicted).abs() > 0.12
          ? error
          : predicted + (1 - math.exp(-gap / 1500)) * (error - predicted);
    }
    _settleUntil ??= now + 8000;
    final settling = now < _settleUntil!;
    final magnitude = _estimate!.abs(), sign = _estimate!.sign.toInt();
    double command() {
      final steps = (magnitude / 6 / 0.005).round() * 0.005;
      _rate = double.parse((1 + _direction * steps.clamp(0.01, 0.04)).toStringAsFixed(3));
      return _rate;
    }

    if (_direction != 0) {
      if (sign != _direction || magnitude <= 0.008) {
        _rest();
        _failures = 0;
        _settleUntil = now;
        return 1;
      }
      if (now - _checkpointAt! >= 5000) {
        if (_checkpointMagnitude! - magnitude < 0.01) {
          _rest();
          _quietUntil = now + math.min(60000, 5000 * math.pow(2, _failures++)).toInt();
          _settleUntil = now;
          return 1;
        }
        _checkpointAt = now;
        _checkpointMagnitude = magnitude;
      }
      return command();
    }
    final frameMargin = math.min(0.025, math.max(0, frameSeconds.isFinite ? frameSeconds : 0) * 0.5);
    final tolerance = settling
        ? math.max(0.02, uncertaintyMs / 1000 * 0.5)
        : math.max(0.03, math.max(frameMargin + 0.01, uncertaintyMs / 1000 * 0.75));
    if (magnitude <= tolerance || now < _quietUntil) {
      _sinceAt = null;
      _sinceSign = null;
      return 1;
    }
    if (_sinceAt == null || _sinceSign != sign) {
      _sinceAt = now;
      _sinceSign = sign;
    }
    if (now - _sinceAt! < (settling ? 500 : 1000)) return 1;
    _direction = sign;
    _sinceAt = _sinceSign = null;
    _checkpointAt = now;
    _checkpointMagnitude = magnitude;
    return command();
  }
}
