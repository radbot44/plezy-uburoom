import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../utils/app_logger.dart';
import '../../utils/web_socket_connect.dart';
import 'clock_sync.dart';

enum UburoomConnectionState { disconnected, connecting, authenticating, connected, reconnecting }

/// The room protocol version this client speaks (uburoom `docs/wire-protocol.md`,
/// `shared/wire-protocol.js`). The server refuses any other in the handshake.
const int uburoomProtocolVersion = 2;

/// The server speaks another protocol version; only updating the app (or the
/// server) helps, so the socket does not retry.
class UburoomProtocolException implements Exception {
  const UburoomProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The server's answer to one request: an `ack` ([status] 200) or an `error`.
/// For an error, [value] is `{'error': message}` plus `rejection` when given.
class UburoomResponse {
  const UburoomResponse({required this.id, required this.status, this.value, this.code});

  final int id;
  final int status;
  final dynamic value;

  /// The error's `code` (`refused`, `invalid`); null for an ack.
  final String? code;

  bool get isSuccess => status >= 200 && status < 300;

  /// The server's message for a refusal.
  String? get error => value is Map ? (value as Map)['error']?.toString() : null;
}

/// The joined room as the server sees it for this tab: the merged `room` and
/// `viewer` lanes ([status] 200), or a refusal. With [rejoin] the room let this
/// tab go and it has to join again.
class UburoomRoomStatePush {
  const UburoomRoomStatePush({required this.roomId, required this.status, this.value, this.rejoin = false});

  final String roomId;
  final int status;
  final dynamic value;
  final bool rejoin;

  bool get isSuccess => status == 200;
  String? get error => value is Map ? (value as Map)['error']?.toString() : null;
}

/// A connection-level refusal: sign-in ended (`auth`), the server is full
/// (`full`) or it cannot publish just now (`unavailable`).
class UburoomUnavailable {
  const UburoomUnavailable({required this.code, required this.status, required this.message});
  final String code;
  final int status;
  final String message;
}

typedef UburoomChannelFactory = Future<WebSocketChannel> Function(Uri uri, String origin);

/// The room connection to an uburoom server: typed messages over `/watch-socket`.
/// Requests are answered by `ack` or `error`; room state arrives as pushed `room`
/// and `viewer` lanes, which this service merges into one snapshot per change.
class UburoomSocketService {
  UburoomSocketService({ClockSync? clockSync, UburoomChannelFactory? channelFactory})
    : clockSync = clockSync ?? ClockSync(),
      _channelFactory = channelFactory ?? _defaultChannelFactory;

  static Future<WebSocketChannel> _defaultChannelFactory(Uri uri, String origin) async {
    final attempt = WebSocketConnectAttempt(
      uri,
      connectTimeout: const Duration(seconds: 10),
      headers: {'Origin': origin},
    );
    // ignore: close_sinks
    final socket = await attempt.socket;
    socket.pingInterval = const Duration(seconds: 15);
    // ignore: close_sinks
    return IOWebSocketChannel(socket);
  }

  final ClockSync clockSync;
  final UburoomChannelFactory _channelFactory;

  UburoomConnectionState _state = UburoomConnectionState.disconnected;
  UburoomConnectionState get state => _state;
  bool get isConnected => _state == UburoomConnectionState.connected;
  bool get isExplicitlyClosed => _explicitlyClosed;
  bool get hasActiveReconnectTimer => _reconnectTimer?.isActive ?? false;

  String? _serverUrl;
  String? _token;
  String? get serverUrl => _serverUrl;
  String? get token => _token;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _clockTimer;
  final List<Timer> _burstTimers = [];
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _explicitlyClosed = false;
  int _seq = 0;

  final Map<int, Completer<UburoomResponse>> _inflight = {};
  final Map<int, ClockRequest> _clockSentAt = {};
  Completer<void>? _authCompleter;

  /// Why the server refused this client's protocol version, once it has.
  UburoomProtocolException? _protocolError;
  UburoomProtocolException? get protocolError => _protocolError;

  // The joined room's two lanes as last received, and the tab they belong to.
  String? _laneRoomId;
  String? _laneViewerId;
  Map<String, dynamic>? _roomLane;
  Map<String, dynamic>? _viewerLane;
  int _roomLaneVersion = -1;
  int _viewerLaneVersion = -1;

  // ignore: close_sinks
  final _connectionStateController = StreamController<UburoomConnectionState>.broadcast();
  final _identityController = StreamController<Map<String, dynamic>>.broadcast();
  final _roomsController = StreamController<dynamic>.broadcast();
  final _roomStateController = StreamController<UburoomRoomStatePush>.broadcast();
  final _roomKickedController = StreamController<String>.broadcast();
  final _unavailableController = StreamController<UburoomUnavailable>.broadcast();

  Stream<UburoomConnectionState> get connectionStateStream => _connectionStateController.stream;
  Stream<Map<String, dynamic>> get identityStream => _identityController.stream;
  Stream<dynamic> get roomsStream => _roomsController.stream;
  Stream<UburoomRoomStatePush> get roomStateStream => _roomStateController.stream;
  Stream<String> get roomKickedStream => _roomKickedController.stream;
  Stream<UburoomUnavailable> get unavailableStream => _unavailableController.stream;

  void _setState(UburoomConnectionState newState) {
    if (_state == newState) return;
    _state = newState;
    _connectionStateController.add(newState);
  }

  /// Connects to the uburoom server and authenticates with [token].
  Future<void> connect({required String serverUrl, required String token}) async {
    _explicitlyClosed = false;
    _protocolError = null;
    _serverUrl = serverUrl;
    _token = token;
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();

    await _performConnect();
  }

  Future<void> _performConnect() async {
    if (_serverUrl == null || _token == null || _explicitlyClosed) return;

    _setState(_reconnectAttempts > 0 ? UburoomConnectionState.reconnecting : UburoomConnectionState.connecting);

    final rawUri = Uri.parse(_serverUrl!);
    final origin = '${rawUri.scheme}://${rawUri.host}${rawUri.hasPort ? ':${rawUri.port}' : ''}';
    final wsScheme = rawUri.scheme == 'https' ? 'wss' : 'ws';
    final wsUri = rawUri.replace(scheme: wsScheme, path: '/watch-socket', query: null);

    try {
      _cleanupChannel();
      final channel = await _channelFactory(wsUri, origin);
      if (_explicitlyClosed) {
        try {
          unawaited(channel.sink.close());
        } catch (_) {}
        return;
      }
      _channel = channel;
      _subscription = channel.stream.listen(_onMessage, onError: _onError, onDone: _onDone, cancelOnError: true);

      _setState(UburoomConnectionState.authenticating);
      _authCompleter = Completer<void>();
      _sendRaw({'type': 'hello', 'protocol': uburoomProtocolVersion, 'token': _token});

      await _authCompleter!.future.timeout(const Duration(seconds: 5));

      if (_explicitlyClosed) {
        _cleanupChannel();
        _setState(UburoomConnectionState.disconnected);
        return;
      }

      _reconnectAttempts = 0;
      _setState(UburoomConnectionState.connected);
      _startClockLoop();
    } catch (error, stackTrace) {
      appLogger.w('UburoomSocketService: connect/auth failed: $error', error: error, stackTrace: stackTrace);
      _cleanupChannel();
      if (error is UburoomProtocolException) {
        // Retrying cannot help; the caller reports it.
        _setState(UburoomConnectionState.disconnected);
        rethrow;
      }
      if (!_explicitlyClosed) {
        _scheduleReconnect();
      } else {
        _setState(UburoomConnectionState.disconnected);
      }
    }
  }

  void _startClockLoop() {
    _clockTimer?.cancel();
    for (final t in _burstTimers) {
      t.cancel();
    }
    _burstTimers.clear();

    // Initial burst of clock exchanges so ClockSync converges (<150ms) before playback starts.
    _sendClockPing();
    for (final delayMs in const [120, 300, 600]) {
      _burstTimers.add(Timer(Duration(milliseconds: delayMs), _sendClockPing));
    }
    _clockTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) => _sendClockPing());
  }

  void _sendClockPing() {
    if (!isConnected) return;
    final id = ++_seq;
    final ping = clockSync.begin();
    _clockSentAt[id] = ping;
    // Clean up stale clock pings older than 10 seconds
    _clockSentAt.removeWhere((_, sendAt) => ping.sent - sendAt.sent > 10000);
    _sendRaw({'type': 'clock', 'id': id});
  }

  /// Sends one request ([message] without its `id`) and awaits its `ack` or
  /// `error`. Every typed request below goes through here.
  Future<UburoomResponse> request(Map<String, dynamic> message, {Duration timeout = const Duration(seconds: 12)}) {
    if (!isConnected) {
      return Future.error(const SocketException('Uburoom socket is not connected'));
    }
    final id = ++_seq;
    final completer = Completer<UburoomResponse>();
    _inflight[id] = completer;
    _sendRaw({...message, 'id': id, 'timeoutMs': timeout.inMilliseconds});
    return completer.future.timeout(
      timeout + const Duration(seconds: 1),
      onTimeout: () {
        _inflight.remove(id);
        _sendRaw({'type': 'cancel', 'id': id});
        throw TimeoutException('Request ${message['type']} timed out', timeout);
      },
    );
  }

  /// Joins [roomId] as [viewerId] (or renews that tab's place: after a
  /// reconnect, or to change `quality` or `delivery`). On success the response's
  /// value is the tab's room snapshot, both lanes merged.
  Future<UburoomResponse> join(
    String roomId,
    String viewerId, {
    String? quality,
    String? delivery,
    Map<String, dynamic> preferences = const {},
    Duration timeout = const Duration(seconds: 35),
  }) async {
    final response = await request({
      'type': 'join',
      'roomId': roomId,
      'viewerId': viewerId,
      'preferences': {...preferences, 'quality': ?quality, 'delivery': ?delivery},
    }, timeout: timeout);
    final value = response.value;
    if (!response.isSuccess || value is! Map) return response;
    final room = value['room'], viewer = value['viewer'];
    if (room is! Map || viewer is! Map || room['state'] is! Map || viewer['state'] is! Map) {
      return UburoomResponse(id: response.id, status: 502, value: const {'error': 'Invalid room state from uburoom.'});
    }
    _laneRoomId = roomId;
    _laneViewerId = viewerId;
    _roomLane = Map<String, dynamic>.from(room['state'] as Map);
    _viewerLane = Map<String, dynamic>.from(viewer['state'] as Map);
    _roomLaneVersion = (room['version'] as num?)?.toInt() ?? 0;
    _viewerLaneVersion = (viewer['version'] as num?)?.toInt() ?? 0;
    return UburoomResponse(id: response.id, status: 200, value: mergeLanes(_roomLane!, _viewerLane!));
  }

  /// Leaves [roomId].
  Future<UburoomResponse> leave(String roomId, String viewerId) {
    if (_laneRoomId == roomId) _forgetLanes();
    return request({'type': 'leave', 'roomId': roomId, 'viewerId': viewerId});
  }

  /// Sends one room command, fenced by the room [epoch] this client last saw
  /// and an [expiresAt] in server time.
  Future<UburoomResponse> command(
    String roomId, {
    required String viewerId,
    required String epoch,
    required int expiresAt,
    required String action,
    Map<String, dynamic>? args,
    Duration timeout = const Duration(seconds: 12),
  }) => request({
    'type': 'command',
    'roomId': roomId,
    'viewerId': viewerId,
    'epoch': epoch,
    'expiresAt': expiresAt,
    'command': {'action': action, 'args': ?args},
  }, timeout: timeout);

  /// Reports whether this tab has buffered the room's current video.
  Future<UburoomResponse> ready(
    String roomId,
    String viewerId, {
    required String mediaVersion,
    required bool ready,
    Object? readinessVersion,
  }) => request({
    'type': 'ready',
    'roomId': roomId,
    'viewerId': viewerId,
    'mediaVersion': mediaVersion,
    'ready': ready,
    'readinessVersion': ?readinessVersion,
  });

  /// Reports what the player actually decoded.
  Future<UburoomResponse> observe(String roomId, String viewerId, Map<String, dynamic> observation) =>
      request({'type': 'observe', 'roomId': roomId, 'viewerId': viewerId, 'observation': observation});

  /// One named request (`CALLS` in uburoom's `shared/wire-protocol.js`), such as
  /// `rooms.list`, `room.reopen` or `room.queue.command`.
  Future<UburoomResponse> call(
    String op, {
    String? roomId,
    Map<String, dynamic>? args,
    Duration timeout = const Duration(seconds: 12),
  }) => request({'type': 'call', 'op': op, 'roomId': ?roomId, 'args': ?args}, timeout: timeout);

  /// Asks the server to send every lane again; completes once it has.
  Future<UburoomResponse> resync() => request({'type': 'resync'});

  /// A tab's view is its two lanes together. `volume` and `muted` belong to the
  /// viewer lane and sit inside the view's `state`.
  static Map<String, dynamic> mergeLanes(Map<String, dynamic> room, Map<String, dynamic> viewer) {
    final own = Map<String, dynamic>.from(viewer)
      ..remove('volume')
      ..remove('muted');
    final state = room['state'];
    return {
      ...room,
      ...own,
      'state': {
        if (state is Map) ...Map<String, dynamic>.from(state),
        'volume': viewer['volume'],
        'muted': viewer['muted'],
      },
    };
  }

  void _forgetLanes() {
    _laneRoomId = _laneViewerId = null;
    _roomLane = _viewerLane = null;
    _roomLaneVersion = _viewerLaneVersion = -1;
  }

  // One pushed lane. The snapshot is published once both lanes describe the same
  // video, so a new video is never paired with the previous video's stream.
  void _onLane(String type, Map<String, dynamic> json) {
    final state = json['state'];
    final version = (json['version'] as num?)?.toInt();
    if (json['roomId'] != _laneRoomId || json['viewerId'] != _laneViewerId || state is! Map || version == null) return;
    if (type == 'room') {
      if (version < _roomLaneVersion) return;
      _roomLaneVersion = version;
      _roomLane = Map<String, dynamic>.from(state);
    } else {
      if (version < _viewerLaneVersion) return;
      _viewerLaneVersion = version;
      _viewerLane = Map<String, dynamic>.from(state);
    }
    final room = _roomLane, viewer = _viewerLane;
    if (room == null || viewer == null || room['mediaVersion'] != viewer['mediaVersion']) return;
    _roomStateController.add(UburoomRoomStatePush(roomId: _laneRoomId!, status: 200, value: mergeLanes(room, viewer)));
  }

  // An `error` with no request id is about the connection or the joined room.
  void _onUnsolicitedError(Map<String, dynamic> json) {
    final code = json['code'] as String? ?? '';
    final status = (json['status'] as num?)?.toInt() ?? 500;
    final message = json['message']?.toString() ?? 'Uburoom request failed ($status).';
    final roomId = json['roomId'] as String?;
    switch (code) {
      case 'protocol':
        _protocolError = UburoomProtocolException(message);
        _explicitlyClosed = true;
        if (_authCompleter != null && !_authCompleter!.isCompleted) _authCompleter!.completeError(_protocolError!);
      case 'removed':
        if (roomId != null) {
          if (roomId == _laneRoomId) _forgetLanes();
          _roomKickedController.add(roomId);
        }
      case 'room':
        if (roomId == null) return;
        final rejoin = json['rejoin'] == true;
        if (rejoin && roomId == _laneRoomId) _forgetLanes();
        _roomStateController.add(
          UburoomRoomStatePush(roomId: roomId, status: status, value: {'error': message}, rejoin: rejoin),
        );
      default:
        if (_state == UburoomConnectionState.authenticating && _authCompleter != null && !_authCompleter!.isCompleted) {
          _authCompleter!.completeError(SocketException(message));
        }
        _unavailableController.add(UburoomUnavailable(code: code, status: status, message: message));
    }
  }

  /// Sends sync-quality telemetry to the server.
  void sendSyncQuality({
    required String roomId,
    required String viewerId,
    required String mediaVersion,
    required String streamVersion,
    required String status,
    double? score,
    String? confidence,
    num? measurementFreshnessMs,
    String? reason,
    Map<String, dynamic>? health,
  }) {
    if (!isConnected) return;
    final Map<String, dynamic> msg = {
      'type': 'quality',
      'roomId': roomId,
      'viewerId': viewerId,
      'mediaVersion': mediaVersion,
      'streamVersion': streamVersion,
      'status': status,
    };
    if (score != null) msg['score'] = score;
    if (confidence != null) msg['confidence'] = confidence;
    if (measurementFreshnessMs != null) msg['measurementFreshnessMs'] = measurementFreshnessMs;
    if (reason != null) msg['reason'] = reason;
    if (health != null) msg['health'] = health;

    _sendRaw(msg);
  }

  void _sendRaw(Map<String, dynamic> data) {
    final channel = _channel;
    if (channel != null) {
      try {
        channel.sink.add(jsonEncode(data));
      } catch (e) {
        appLogger.w('UburoomSocketService: sendRaw failed: $e');
      }
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final json = jsonDecode(raw.toString()) as Map<String, dynamic>;
      final type = json['type'] as String?;

      switch (type) {
        case 'welcome':
          if (_authCompleter != null && !_authCompleter!.isCompleted) {
            _authCompleter!.complete();
          }
          break;
        case 'clock':
          final id = json['id'] as int?;
          if (id != null) {
            final sendAt = _clockSentAt.remove(id);
            if (sendAt != null) {
              final timing = json['timing'] as Map<String, dynamic>?;
              if (timing is Map<String, dynamic>) clockSync.add(sendAt, timing);
            }
          }
          break;
        case 'ack':
          final id = json['id'] as int?;
          if (id != null) {
            _inflight.remove(id)?.complete(UburoomResponse(id: id, status: 200, value: json['value']));
          }
          break;
        case 'error':
          final id = json['id'] as int?;
          if (id == null) {
            _onUnsolicitedError(json);
            break;
          }
          _inflight
              .remove(id)
              ?.complete(
                UburoomResponse(
                  id: id,
                  status: (json['status'] as num?)?.toInt() ?? 500,
                  code: json['code'] as String?,
                  value: {
                    'error': json['message']?.toString() ?? 'Uburoom request failed.',
                    'rejection': ?json['rejection'],
                  },
                ),
              );
          break;
        case 'lobby':
          final identity = json['identity'];
          if (identity is Map<String, dynamic>) _identityController.add(identity);
          _roomsController.add(json['rooms']);
          break;
        case 'room':
        case 'viewer':
          _onLane(type!, json);
          break;
      }
    } catch (e, st) {
      appLogger.w('UburoomSocketService: parse error: $e', error: e, stackTrace: st);
    }
  }

  void _onError(Object error) {
    appLogger.w('UburoomSocketService: socket error: $error');
    _handleDisconnect();
  }

  void _onDone() {
    appLogger.d('UburoomSocketService: socket done');
    _handleDisconnect();
  }

  void _handleDisconnect() {
    _cleanupChannel();
    if (!_explicitlyClosed && _protocolError == null && _serverUrl != null && _token != null) {
      _scheduleReconnect();
    } else {
      _setState(UburoomConnectionState.disconnected);
    }
  }

  void _scheduleReconnect() {
    if (_explicitlyClosed) return;
    _setState(UburoomConnectionState.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    final delaySeconds = math.min(10, 1 << math.min(4, _reconnectAttempts - 1));
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!_explicitlyClosed) {
        // A protocol refusal ends the retries; whoever connects next hears of it.
        unawaited(_performConnect().catchError((Object _) {}));
      }
    });
  }

  void _cleanupChannel() {
    _clockTimer?.cancel();
    _clockTimer = null;
    for (final t in _burstTimers) {
      t.cancel();
    }
    _burstTimers.clear();
    _clockSentAt.clear();
    clockSync.reset();

    for (final completer in _inflight.values) {
      if (!completer.isCompleted) {
        completer.completeError(const SocketException('Connection closed'));
      }
    }
    _inflight.clear();

    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.completeError(const SocketException('Connection closed before authentication'));
    }
    _authCompleter = null;

    try {
      _subscription?.cancel();
    } catch (_) {}
    _subscription = null;

    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  /// Closes the connection and cancels reconnection attempts.
  Future<void> disconnect() async {
    _explicitlyClosed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _cleanupChannel();
    _setState(UburoomConnectionState.disconnected);
  }

  void dispose() {
    disconnect();
    _connectionStateController.close();
    _identityController.close();
    _roomsController.close();
    _roomStateController.close();
    _roomKickedController.close();
    _unavailableController.close();
  }
}
