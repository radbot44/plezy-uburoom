import 'dart:async';
import 'dart:math' as math;

import '../../utils/app_logger.dart';
import 'clock_sync.dart';
import 'player_adapter.dart';
import 'uburoom_socket_service.dart';

/// Server-authoritative playback reconciler for an uburoom room viewer.
/// Reconciles local [PlezyPlayerAdapter] against uburoom's timeline.
class GuestPlaybackReconciler {
  GuestPlaybackReconciler({
    required this.adapter,
    required this.clockSync,
    required this.socketService,
    required this.roomId,
    required this.viewerId,
  }) {
    _stateSub = socketService.roomStateStream.listen(_onRoomStatePush);
    _tickTimer = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
    _observeTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) => _dispatchObservation());
    _syncQualityTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) => _dispatchSyncQuality());

    _playingSub = adapter.player.streams.playing.listen((_) => _onPlayerStateEvent('playing'));
    _bufferingSub = adapter.player.streams.buffering.listen((b) => _onPlayerStateEvent(b ? 'buffering' : 'playing'));
    _completedSub = adapter.player.streams.completed.listen((c) => _onPlayerStateEvent(c ? 'ended' : 'playing'));
  }

  static final _uuidPattern = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$');

  final PlezyPlayerAdapter adapter;
  final ClockSync clockSync;
  final UburoomSocketService socketService;
  final String roomId;
  final String viewerId;

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
  int _revision = 0;
  String _mediaVersion = '';
  String _streamVersion = '';
  String _observationEpoch = '';
  int _observationSequence = 0;
  double _lastSampleAt = 0.0;
  int _frames = 0;
  int _discontinuity = 0;
  bool _observationPending = false;
  String _lastReportedState = 'paused';

  int _lastSyncQualitySentAt = 0;
  String _lastSyncQualityStatus = '';
  String _lastSyncQualityConfidence = '';

  int _startAt = 0;
  int _pauseAt = 0;
  bool _paused = true;
  double _roomRate = 1.0;
  bool _waitingForReady = false;
  dynamic _readinessVersion;
  bool _seekInFlight = false;

  int _lastSeekAt = 0;
  double _currentSlewRate = 1.0;
  bool _readySentForCurrentVersion = false;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  double get roomRate => _roomRate;
  bool get waitingForReady => _waitingForReady;
  int get discontinuity => _discontinuity;
  int get frames => _frames;
  String get observationEpoch => _observationEpoch;
  String get epoch => _epoch;
  String? get readinessVersion => _readinessVersion;

  void updateRoomSnapshot(Map<String, dynamic> snapshot) {
    _lastSnapshot = snapshot;
    final room = snapshot['room'] as Map<String, dynamic>? ?? snapshot;
    final epochVal = snapshot['epoch'] ?? room['epoch'];
    if (epochVal != null) {
      _epoch = epochVal.toString();
    }
    _revision = room['revision'] as int? ?? _revision;

    final newMediaVersion = (snapshot['mediaVersion'] ?? room['mediaVersion']) as String? ?? '';
    final newStreamVersion = (snapshot['streamVersion'] ?? room['streamVersion']) as String? ?? '';
    final newReadinessVersion =
        snapshot['readinessVersion'] ?? (snapshot['readiness'] as Map<String, dynamic>?)?['version'];
    final newWaitingForReady = snapshot['waitingForReady'] as bool? ?? false;
    final waitingTransition = !_waitingForReady && newWaitingForReady;

    if (newMediaVersion != _mediaVersion ||
        newStreamVersion != _streamVersion ||
        newReadinessVersion != _readinessVersion ||
        waitingTransition) {
      _mediaVersion = newMediaVersion;
      _streamVersion = newStreamVersion;
      _readinessVersion = newReadinessVersion;
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
    _paused = stateObj?['paused'] as bool? ?? (snapshot['paused'] as bool? ?? true);
    _roomRate = (stateObj?['rate'] as num?)?.toDouble() ?? 1.0;

    _waitingForReady = newWaitingForReady;

    _handleReadinessGate();
    _handleStartCountdown();
  }

  void _onRoomStatePush(UburoomRoomStatePush push) {
    if (_disposed) return;
    if (push.path.startsWith('/api/watch/rooms/$roomId') && push.value is Map<String, dynamic>) {
      updateRoomSnapshot(push.value as Map<String, dynamic>);
    }
  }

  void _onPlayerStateEvent(String event) {
    if (_disposed) return;
    final newState = _currentState;
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

    final targetPos = targetPositionMs;
    final driftMs = adapter.positionMs - targetPos;
    final threshold = _readinessVersion != null ? 50 : 250;

    final now = clockSync.serverNow;
    if (driftMs.abs() > threshold && !_seekInFlight && now - _lastSeekAt > 400) {
      _lastSeekAt = now;
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

    final isLoaded =
        (adapter.firstFrameShown || adapter.player.state.seekable || adapter.durationMs != null) &&
        !adapter.isHeld &&
        !adapter.buffering &&
        !_seekInFlight;

    if (isLoaded && driftMs.abs() <= 500) {
      _readySentForCurrentVersion = true;
      unawaited(_sendReady());
    }
  }

  Future<void> _sendReady() async {
    try {
      final res = await socketService.sendRequest('/api/watch/rooms/$roomId/ready', {
        'viewerId': viewerId,
        'mediaVersion': _mediaVersion,
        'ready': true,
        if (_readinessVersion != null) 'readinessVersion': _readinessVersion,
      });
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

    if (_paused || _waitingForReady) return;

    final serverNow = clockSync.serverNow;
    if (_startAt > serverNow) {
      final waitMs = _startAt - serverNow;
      if (!adapter.paused) {
        unawaited(adapter.pause());
      }
      _startTimer = Timer(Duration(milliseconds: waitMs), () {
        if (!_disposed && !_paused && !_waitingForReady) {
          unawaited(adapter.play());
        }
      });
    }
  }

  int get targetPositionMs {
    final snapshot = _lastSnapshot;
    if (snapshot == null) return math.max(0, _pauseAt);

    final serverTime = clockSync.serverNow;
    final int? serverNow = snapshot['serverNow'] as int?;
    if (serverNow == null) {
      final stateObj = snapshot['state'] as Map<String, dynamic>?;
      if (stateObj != null && stateObj['position'] is num) {
        return ((stateObj['position'] as num).toDouble() * 1000).round();
      }
      if (_paused) return math.max(0, _pauseAt);
      final int startAt = snapshot['startAt'] as int? ?? _startAt;
      if (serverTime < startAt) return 0;
      return math.max(0, ((serverTime - startAt) * _roomRate).round());
    }

    final stateObj = snapshot['state'] as Map<String, dynamic>?;
    final double statePosition = (stateObj?['position'] as num?)?.toDouble() ?? (_pauseAt / 1000.0);
    final double duration = (stateObj?['duration'] as num?)?.toDouble() ?? 0.0;
    final bool isPaused = stateObj?['paused'] as bool? ?? _paused;

    var effectiveServerTime = serverTime;
    final int? pauseAt = snapshot['pauseAt'] as int?;
    if (pauseAt != null) {
      effectiveServerTime = math.min(effectiveServerTime, pauseAt);
    }

    final int? startAt = snapshot['startAt'] as int?;
    final int elapsedMs = startAt != null
        ? math.max(0, effectiveServerTime - math.max(serverNow, startAt))
        : (effectiveServerTime - serverNow);

    final double targetSeconds = math.max(
      0.0,
      math.min(duration > 0 ? duration : double.infinity, statePosition + (isPaused ? 0.0 : elapsedMs / 1000.0)),
    );

    return (targetSeconds * 1000).round();
  }

  void _tick() {
    if (_disposed || adapter.isReleased || _lastSnapshot == null) return;

    final now = clockSync.serverNow;

    if (_waitingForReady) {
      if (!adapter.paused) unawaited(adapter.pause());

      final targetPos = targetPositionMs;
      final driftMs = adapter.positionMs - targetPos;
      final threshold = _readinessVersion != null ? 50 : 250;

      if (driftMs.abs() > threshold && !_seekInFlight && now - _lastSeekAt > 400) {
        _lastSeekAt = now;
        _seekInFlight = true;
        _discontinuity++;
        unawaited(
          adapter.seek(targetPos).whenComplete(() {
            _seekInFlight = false;
          }),
        );
        return;
      }

      final isLoaded =
          (adapter.firstFrameShown || adapter.player.state.seekable || adapter.durationMs != null) &&
          !adapter.isHeld &&
          !adapter.buffering &&
          !_seekInFlight;

      if (!_readySentForCurrentVersion && isLoaded && driftMs.abs() <= 500) {
        _readySentForCurrentVersion = true;
        unawaited(_sendReady());
      }
      return;
    }

    if (_startAt > now) return;

    final targetPos = targetPositionMs;
    final currentPos = adapter.positionMs;
    final driftMs = currentPos - targetPos;

    if (_paused) {
      if (!adapter.paused) unawaited(adapter.pause());
      if (driftMs.abs() > 500 && now - _lastSeekAt > 1500 && !_seekInFlight) {
        _lastSeekAt = now;
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

    if (driftMs.abs() <= 350) {
      if (_currentSlewRate != 1.0 && adapter.canSetRate) {
        _currentSlewRate = 1.0;
        unawaited(adapter.setRate(_roomRate));
      }
      return;
    }

    if (driftMs.abs() <= 2000 && adapter.canSetRate) {
      final double targetSlew = driftMs < 0 ? (_roomRate * 1.04) : (_roomRate * 0.96);
      if ((_currentSlewRate - targetSlew).abs() > 0.005) {
        _currentSlewRate = targetSlew;
        unawaited(adapter.setRate(targetSlew));
      }
      return;
    }

    if (now - _lastSeekAt > 1500 && !adapter.buffering && !adapter.isHeld && !_seekInFlight) {
      _lastSeekAt = now;
      _seekInFlight = true;
      _discontinuity++;
      if (_currentSlewRate != 1.0 && adapter.canSetRate) {
        _currentSlewRate = 1.0;
        unawaited(adapter.setRate(_roomRate));
      }
      unawaited(
        adapter.seek(targetPos).whenComplete(() {
          _seekInFlight = false;
        }),
      );
    }
  }

  void _dispatchObservation() {
    if (_disposed || !socketService.isConnected) return;
    if (_mediaVersion.isEmpty || _streamVersion.isEmpty || _observationEpoch.isEmpty) return;
    if (_observationPending) return;

    final state = _currentState;
    final nowMs = DateTime.now().millisecondsSinceEpoch.toDouble();
    final sampleAt = nowMs > _lastSampleAt ? nowMs : (_lastSampleAt + 1.0);
    final elapsedMs = _lastSampleAt > 0 ? (sampleAt - _lastSampleAt) : 1000.0;
    _lastSampleAt = sampleAt;

    if (state == 'playing') {
      final deltaFrames = math.max(1, ((elapsedMs / 1000.0) * 24.0).round());
      _frames += deltaFrames;
    }

    final observedAt = clockSync.serverNow;
    final double positionSeconds = adapter.positionMs / 1000.0;
    final double rate = adapter.canSetRate ? _currentSlewRate * _roomRate : 1.0;
    final sequence = ++_observationSequence;

    final data = <String, dynamic>{
      'viewerId': viewerId,
      'epoch': _epoch,
      'mediaVersion': _mediaVersion,
      'streamVersion': _streamVersion,
      'observationEpoch': _observationEpoch,
      'sequence': sequence,
      'sampleAt': sampleAt,
      'observedAt': observedAt,
      'position': positionSeconds,
      'rate': rate,
      'frames': _frames,
      'discontinuity': _discontinuity,
      'state': state,
    };

    _observationPending = true;
    unawaited(
      socketService
          .sendRequest('/api/watch/rooms/$roomId/observe', data)
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

  void _dispatchSyncQuality() {
    if (_disposed || !socketService.isConnected) return;
    if (!_uuidPattern.hasMatch(roomId) ||
        !_uuidPattern.hasMatch(viewerId) ||
        !_uuidPattern.hasMatch(_mediaVersion) ||
        !_uuidPattern.hasMatch(_streamVersion)) {
      return;
    }

    final currentPos = adapter.positionMs;
    final targetPos = targetPositionMs;
    final driftMs = currentPos - targetPos;

    final String status = adapter.buffering
        ? 'buffering'
        : (adapter.player.state.completed ? 'paused' : (adapter.paused ? 'paused' : 'playing'));

    final double score = (1.0 - (driftMs.abs() / 2000.0)).clamp(0.0, 1.0);
    final String confidence = clockSync.isSynchronized ? 'confident' : 'reduced';

    final now = DateTime.now().millisecondsSinceEpoch;
    final bool statusChanged = status != _lastSyncQualityStatus;
    final bool confidenceChanged = confidence != _lastSyncQualityConfidence;
    final int minInterval = (statusChanged || confidenceChanged) ? 500 : 4000;

    if (now - _lastSyncQualitySentAt < minInterval) return;

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
      measurementFreshnessMs: 0,
    );
  }

  void dispose() {
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
