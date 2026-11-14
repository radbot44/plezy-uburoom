import 'dart:async';
import 'dart:math' as math;

import '../../utils/app_logger.dart';
import 'clock_sync.dart';
import 'drift_correction.dart';
import 'player_adapter.dart';
import 'uburoom_socket_service.dart';

/// Server-authoritative playback reconciler for an uburoom room viewer.
/// Reconciles local [PlezyPlayerAdapter] against uburoom's timeline using
/// the same uncertainty-aware converge-then-rest controller as web viewers.
class GuestPlaybackReconciler {
  GuestPlaybackReconciler({
    required this.adapter,
    required this.clockSync,
    required this.socketService,
    required this.roomId,
    required this.viewerId,
    this.listenToRoomStateStream = true,
  }) {
    if (listenToRoomStateStream) {
      _stateSub = socketService.roomStateStream.listen(_onRoomStatePush);
    }
    _tickTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    _observeTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) => _dispatchObservation());
    _syncQualityTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) => _dispatchSyncQuality());

    _playingSub = adapter.player.streams.playing.listen((_) => _onPlayerStateEvent('playing'));
    _bufferingSub = adapter.player.streams.buffering.listen((b) => _onPlayerStateEvent(b ? 'buffering' : 'playing'));
    _completedSub = adapter.player.streams.completed.listen((c) => _onPlayerStateEvent(c ? 'ended' : 'playing'));
  }

  static final _uuidPattern = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
    caseSensitive: false,
  );
  static final _roomIdPattern = RegExp(
    r'^([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}|[a-f0-9]{8})$',
    caseSensitive: false,
  );

  // Web client leaves errors above 650 ms to alignment seeks. Native seeks
  // await landing via the adapter; do not issue another while one is pending.
  static const int _hardSeekThresholdMs = 650;
  final DriftCorrection _correction = DriftCorrection();

  final PlezyPlayerAdapter adapter;
  final ClockSync clockSync;
  final UburoomSocketService socketService;
  final String roomId;
  final String viewerId;
  final bool listenToRoomStateStream;

  StreamSubscription? _stateSub;
  StreamSubscription? _playingSub;
  StreamSubscription? _bufferingSub;
  StreamSubscription? _completedSub;

  Timer? _tickTimer;
  Timer? _observeTimer;
  Timer? _syncQualityTimer;
  Timer? _startTimer;

  Map<String, dynamic>? _lastSnapshot;
  String _epoch = '';
  String _mediaVersion = '';
  String _streamVersion = '';
  String _observationEpoch = '';
  int _observationSequence = 0;
  double _lastSampleAt = 0.0;

  int _discontinuity = 0;
  bool _observationPending = false;
  int? _lastFrames;
  String _lastReportedState = 'paused';

  int _lastSyncQualitySentAt = 0;
  String _lastSyncQualityStatus = '';
  String _lastSyncQualityConfidence = '';

  int _startAt = 0;
  int _pauseAt = 0;
  bool _paused = true;
  static const double _roomRate = 1.0;
  bool _waitingForReady = false;
  dynamic _readinessVersion;
  bool _seekInFlight = false;

  double _currentSlewRate = 1.0;
  bool _isSlewing = false;

  bool _readySentForCurrentVersion = false;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  double get roomRate => _roomRate;
  bool get waitingForReady => _waitingForReady;
  bool get isSlewing => _isSlewing;
  int get discontinuity => _discontinuity;

  String get observationEpoch => _observationEpoch;
  String get epoch => _epoch;
  String? get readinessVersion => _readinessVersion?.toString();

  void updateRoomSnapshot(Map<String, dynamic> snapshot) {
    final prevPaused = _paused;
    final prevWaitingForReady = _waitingForReady;

    _lastSnapshot = snapshot;

    final epochVal = snapshot['epoch'];
    if (epochVal != null) {
      _epoch = epochVal.toString();
    }

    final newMediaVersion = snapshot['mediaVersion'] as String? ?? '';
    final newStreamVersion = snapshot['streamVersion'] as String? ?? '';
    final newReadinessVersion = snapshot['readinessVersion'];
    final newWaitingForReady = snapshot['waitingForReady'] as bool? ?? false;
    final waitingTransition = !_waitingForReady && newWaitingForReady;

    if (newMediaVersion != _mediaVersion ||
        newStreamVersion != _streamVersion ||
        newReadinessVersion != _readinessVersion ||
        waitingTransition) {
      _mediaVersion = newMediaVersion;
      _streamVersion = newStreamVersion;
      _readinessVersion = newReadinessVersion;
      _correction.reset();
      _lastFrames = null;
      _readySentForCurrentVersion = false;
    } else {
      _mediaVersion = newMediaVersion;
      _streamVersion = newStreamVersion;
      _readinessVersion = newReadinessVersion;
    }

    final newObsEpoch = (snapshot['observationEpoch'] as String?) ?? '';
    if (newObsEpoch.isNotEmpty && newObsEpoch != _observationEpoch) {
      _observationEpoch = newObsEpoch;
      _observationSequence = 0;
    }

    _startAt = snapshot['startAt'] as int? ?? 0;
    _pauseAt = snapshot['pauseAt'] as int? ?? 0;

    final stateObj = snapshot['state'] as Map<String, dynamic>?;
    _paused = stateObj?['paused'] as bool? ?? true;

    _waitingForReady = newWaitingForReady;

    final bool pausedTransition =
        _paused && !_waitingForReady && (!prevPaused || prevWaitingForReady || !adapter.paused);

    if (pausedTransition) {
      if (!adapter.paused) {
        unawaited(adapter.pause());
      }
      _resetSlewIfNeeded();
      final targetPos = targetPositionMs;
      final drift = (adapter.positionMs - targetPos).abs();
      if (drift > 650 && !_seekInFlight) {
        _seekInFlight = true;
        _discontinuity++;

        unawaited(
          adapter.seek(targetPos).whenComplete(() {
            _seekInFlight = false;
          }),
        );
      }
    }

    _handleReadinessGate();
    _handleStartCountdown();

    if (prevWaitingForReady != _waitingForReady || prevPaused != _paused) {
      _dispatchSyncQuality(force: true);
    }
  }

  void _onRoomStatePush(UburoomRoomStatePush push) {
    if (_disposed) return;
    if (push.roomId == roomId && push.isSuccess && push.value is Map<String, dynamic>) {
      updateRoomSnapshot(push.value as Map<String, dynamic>);
    }
  }

  void _onPlayerStateEvent(String event) {
    if (_disposed) return;
    final newState = _currentState;
    if (newState == 'paused' || newState == 'buffering' || newState == 'ended') _resetSlewIfNeeded();
    if (_lastReportedState != newState) {
      // Natural EOF transition playing -> ended does NOT increment discontinuity
      if (newState != 'ended' &&
          !(_lastReportedState == 'playing' && newState == 'ended') &&
          !(newState == 'paused' && adapter.player.state.completed)) {
        _discontinuity++;
      }
      _lastReportedState = newState;
      _dispatchObservation();
    }
  }

  String get _currentState {
    if (adapter.player.state.completed) return 'ended';
    if (adapter.buffering) return 'buffering';
    if (adapter.paused) return 'paused';
    return 'playing';
  }

  void _handleReadinessGate() {
    if (_disposed || !_waitingForReady || _readySentForCurrentVersion) return;
    if (_mediaVersion.isEmpty) return;

    if (!adapter.paused) unawaited(adapter.pause());
    _resetSlewIfNeeded();

    final targetPos = targetPositionMs;
    final driftMs = adapter.positionMs - targetPos;
    const threshold = 50;

    if (driftMs.abs() > threshold && !_seekInFlight) {
      _seekInFlight = true;
      _discontinuity++;
      unawaited(
        adapter.seek(targetPos).whenComplete(() {
          _seekInFlight = false;
          _handleReadinessGate();
        }),
      );
      return;
    }

    final isLoaded = adapter.firstFrameShown && !adapter.isHeld && !adapter.buffering && !_seekInFlight;

    if (isLoaded && driftMs.abs() <= 50) {
      _readySentForCurrentVersion = true;
      unawaited(_sendReady());
    }
  }

  Future<void> _sendReady() async {
    try {
      final res = await socketService.ready(
        roomId,
        viewerId,
        mediaVersion: _mediaVersion,
        ready: true,
        readinessVersion: _readinessVersion,
      );
      if (!res.isSuccess) {
        _readySentForCurrentVersion = false;
        appLogger.w('GuestPlaybackReconciler: sendReady returned status ${res.status}: ${res.value}');
        return;
      }
      appLogger.d('GuestPlaybackReconciler: sent ready for mediaVersion=$_mediaVersion');
    } catch (e) {
      appLogger.w('GuestPlaybackReconciler: sendReady failed: $e');
      _readySentForCurrentVersion = false;
    }
  }

  void _handleStartCountdown() {
    _startTimer?.cancel();
    _startTimer = null;

    if (_paused || _waitingForReady || !clockSync.isSynchronized) return;

    final serverNow = clockSync.serverNow;
    if (_startAt > serverNow) {
      final waitMs = _startAt - serverNow;
      if (!adapter.paused) {
        unawaited(adapter.pause());
      }
      _startTimer = Timer(Duration(milliseconds: waitMs), () {
        if (!_disposed && !_paused && !_waitingForReady && clockSync.isSynchronized) {
          if (clockSync.serverNow < _startAt) {
            _handleStartCountdown();
            return;
          }
          unawaited(adapter.play());
        }
      });
    }
  }

  // timing.mjs target(): the server publishes an anchored position, never a
  // continuously pushed playhead. Moving timelines require a valid mapping.
  int get targetPositionMs {
    final snapshot = _lastSnapshot;
    if (snapshot == null) return 0;
    final state = snapshot['state'] as Map<String, dynamic>? ?? const {};
    final position = (state['position'] as num?)?.toDouble() ?? 0;
    final duration = (state['duration'] as num?)?.toDouble() ?? 0;
    double target = position;
    if (state['paused'] != true && clockSync.isSynchronized) {
      final anchor = snapshot['serverNow'] as num?;
      if (anchor != null) {
        num time = clockSync.serverNow;
        final pauseAt = snapshot['pauseAt'] as num?;
        if (pauseAt != null) time = math.min(time, pauseAt);
        final startAt = snapshot['startAt'] as num?;
        final elapsed = startAt != null ? math.max(0, time - math.max(anchor, startAt)) : time - anchor;
        target += elapsed / 1000;
      }
    }
    return (target.clamp(0, duration) * 1000).round();
  }

  void _resetSlewIfNeeded() {
    _isSlewing = false;
    _correction.reset();
    if (_currentSlewRate != 1.0 && adapter.canSetRate) {
      _currentSlewRate = 1.0;
      unawaited(adapter.setRate(_roomRate));
    }
  }

  void _tick() {
    if (_disposed || adapter.isReleased || _lastSnapshot == null) return;

    final now = clockSync.serverNow;

    if (_waitingForReady) {
      if (!adapter.paused) unawaited(adapter.pause());
      _resetSlewIfNeeded();

      final targetPos = targetPositionMs;
      final driftMs = adapter.positionMs - targetPos;
      const threshold = 50;

      if (driftMs.abs() > threshold && !_seekInFlight) {
        _seekInFlight = true;
        _discontinuity++;
        unawaited(
          adapter.seek(targetPos).whenComplete(() {
            _seekInFlight = false;
          }),
        );
        return;
      }

      final isLoaded = adapter.firstFrameShown && !adapter.isHeld && !adapter.buffering && !_seekInFlight;

      if (!_readySentForCurrentVersion && isLoaded && driftMs.abs() <= 50) {
        _readySentForCurrentVersion = true;
        unawaited(_sendReady());
      }
      return;
    }

    if (!_paused && !clockSync.isSynchronized) {
      // Match web: a pending scheduled start holds; already-running playback
      // continues at nominal rate until a usable clock returns.
      if (_startAt > (_lastSnapshot?['serverNow'] as num? ?? 0) && !adapter.paused) {
        unawaited(adapter.pause());
      }
      _resetSlewIfNeeded();
      return;
    }
    if (_startAt > now) {
      _handleStartCountdown();
      return;
    }

    final targetPos = targetPositionMs;
    final currentPos = adapter.positionMs;
    final driftMs = currentPos - targetPos;
    final absDrift = driftMs.abs();

    if (adapter.player.state.completed &&
        currentPos >= (adapter.durationMs ?? 0) - 500 &&
        targetPos >= (adapter.durationMs ?? 0) - 500) {
      _resetSlewIfNeeded();
      return;
    }

    if (_paused || (_pauseAt > 0 && now >= _pauseAt)) {
      if (!adapter.paused) unawaited(adapter.pause());
      _resetSlewIfNeeded();
      if (absDrift > 650 && !_seekInFlight) {
        _seekInFlight = true;
        _discontinuity++;
        unawaited(
          adapter.seek(targetPos).whenComplete(() {
            _seekInFlight = false;
          }),
        );
      }
      return;
    }

    if (adapter.paused && !adapter.isHeld) {
      unawaited(adapter.play());
    }

    // Web alignment threshold: errors above 650 ms require a local seek.
    if (absDrift > _hardSeekThresholdMs) {
      if (!adapter.buffering && !adapter.isHeld && !_seekInFlight) {
        _seekInFlight = true;
        _discontinuity++;
        _resetSlewIfNeeded();
        unawaited(
          adapter.seek(targetPos).whenComplete(() {
            _seekInFlight = false;
          }),
        );
      }
      return;
    }

    final timing = clockSync.read();
    final factor = _correction.update(
      now: clockSync.monotonicNow,
      error: -driftMs / 1000.0,
      eligible:
          timing.valid &&
          adapter.canSetRate &&
          !adapter.paused &&
          !adapter.buffering &&
          !adapter.isHeld &&
          !_seekInFlight &&
          adapter.firstFrameShown &&
          (_bufferAhead == null || _bufferAhead! >= 1),
      context:
          '$_epoch:$_mediaVersion:$_streamVersion:${_lastSnapshot?['revision']}:$_startAt:$_pauseAt:$_readinessVersion:${clockSync.revision}',
      uncertaintyMs: timing.uncertainty,
      stabilityMs: timing.stability,
    );
    _isSlewing = factor != 1;
    if (_currentSlewRate != factor && adapter.canSetRate) {
      _currentSlewRate = factor;
      unawaited(adapter.setRate(factor));
    }
  }

  double? get _bufferAhead {
    final state = adapter.player.state;
    if (state.bufferRanges.isEmpty && state.buffer == Duration.zero) return null;
    final position = adapter.player.currentPosition;
    double ahead = math.max(0, (adapter.player.state.buffer - position).inMilliseconds / 1000.0);
    for (final range in adapter.player.state.bufferRanges) {
      if (position >= range.start && position <= range.end) {
        ahead = math.max(ahead, (range.end - position).inMilliseconds / 1000.0);
      }
    }
    return ahead;
  }

  Future<void> _dispatchObservation() async {
    if (_disposed || !socketService.isConnected) return;
    if (_mediaVersion.isEmpty || _streamVersion.isEmpty || _observationEpoch.isEmpty) return;
    if (_observationPending) return;

    _observationPending = true;
    final context = '$_mediaVersion:$_streamVersion:$_observationEpoch';
    int frames = 0;
    try {
      // Android ExoPlayer's existing stats bridge exposes DecoderCounters.
      // mpv's estimated-frame-number/count are position estimates, not evidence.
      final stats = await adapter.player.getStats();
      final rendered = stats['videoRenderedFrames'];
      if (rendered is int && rendered >= 0) frames = rendered;
    } catch (_) {
      // Backends without a real counter explicitly report no decode evidence.
    }
    if (_disposed || adapter.isReleased || context != '$_mediaVersion:$_streamVersion:$_observationEpoch') {
      _observationPending = false;
      return;
    }
    if (_lastFrames != null && frames < _lastFrames!) _discontinuity++;
    _lastFrames = frames;
    final state = _currentState;
    final nowMs = clockSync.monotonicNow.toDouble();
    final sampleAt = nowMs > _lastSampleAt ? nowMs : (_lastSampleAt + 1.0);
    _lastSampleAt = sampleAt;
    // Zero is a valid observation, but cannot earn decode-backed watch credit.

    final observedAt = clockSync.serverNow;
    final double positionSeconds = adapter.positionMs / 1000.0;
    final double rate = adapter.player.state.rate;
    final sequence = ++_observationSequence;

    final data = <String, dynamic>{
      'epoch': _epoch,
      'mediaVersion': _mediaVersion,
      'streamVersion': _streamVersion,
      'observationEpoch': _observationEpoch,
      'sequence': sequence,
      'sampleAt': sampleAt,
      'observedAt': observedAt,
      'position': positionSeconds,
      'rate': rate,
      'frames': frames,
      'discontinuity': _discontinuity,
      'state': state,
    };

    unawaited(
      socketService
          .observe(roomId, viewerId, data)
          .then((response) {
            if (response.status == 409) {
              _observationSequence = 0;
            }
          })
          .catchError((e) {
            appLogger.d('GuestPlaybackReconciler: observe dispatch failed: $e');
          })
          .whenComplete(() {
            _observationPending = false;
          }),
    );
  }

  void _dispatchSyncQuality({bool force = false}) {
    if (_disposed || !socketService.isConnected) return;
    if (!_roomIdPattern.hasMatch(roomId) ||
        !_uuidPattern.hasMatch(viewerId) ||
        _mediaVersion.isEmpty ||
        _streamVersion.isEmpty) {
      return;
    }

    final currentPos = adapter.positionMs;
    final targetPos = targetPositionMs;
    final driftMs = currentPos - targetPos;

    final String status = adapter.buffering
        ? 'buffering'
        : (adapter.player.state.completed
              ? 'paused'
              : ((adapter.paused || _paused || _waitingForReady) ? 'paused' : 'playing'));

    final double score = (1.0 - (driftMs.abs() / 2000.0)).clamp(0.0, 1.0);
    final String confidence = clockSync.isSynchronized ? 'confident' : 'reduced';

    final now = DateTime.now().millisecondsSinceEpoch;
    final bool statusChanged = status != _lastSyncQualityStatus;
    final bool confidenceChanged = confidence != _lastSyncQualityConfidence;
    final int minInterval = (statusChanged || confidenceChanged) ? 500 : 4000;

    if (!force && now - _lastSyncQualitySentAt < minInterval) return;

    _lastSyncQualitySentAt = now;
    _lastSyncQualityStatus = status;
    _lastSyncQualityConfidence = confidence;

    socketService.sendSyncQuality(
      roomId: roomId,
      viewerId: viewerId,
      mediaVersion: _mediaVersion,
      streamVersion: _streamVersion,
      status: status,
      score: score,
      confidence: confidence,
      measurementFreshnessMs: clockSync.measurementFreshnessMs(now),
      health: {
        if (_bufferAhead case final double ahead) 'bufferAhead': ahead.clamp(0, 3600),
        if (clockSync.isSynchronized) 'offsetMs': driftMs.clamp(-86400000, 86400000),
        if (_lastSnapshot?['quality'] is String) 'quality': _lastSnapshot!['quality'],
      },
    );
  }

  void dispose() {
    if (_currentSlewRate != 1.0 && adapter.canSetRate && !adapter.isReleased) {
      _currentSlewRate = 1.0;
      unawaited(adapter.setRate(1.0));
    }
    _disposed = true;
    _tickTimer?.cancel();
    _tickTimer = null;
    _observeTimer?.cancel();
    _observeTimer = null;
    _syncQualityTimer?.cancel();
    _syncQualityTimer = null;
    _startTimer?.cancel();
    _startTimer = null;
    _stateSub?.cancel();
    _stateSub = null;
    _playingSub?.cancel();
    _playingSub = null;
    _bufferingSub?.cancel();
    _bufferingSub = null;
    _completedSub?.cancel();
    _completedSub = null;
  }
}
