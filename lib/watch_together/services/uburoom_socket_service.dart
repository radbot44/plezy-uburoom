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

class UburoomResponse {
  const UburoomResponse({required this.id, required this.status, this.value});

  final int id;
  final int status;
  final dynamic value;

  bool get isSuccess => status >= 200 && status < 300;
}

class UburoomRoomStatePush {
  const UburoomRoomStatePush({required this.path, required this.status, this.value});

  final String path;
  final int status;
  final dynamic value;
}

typedef UburoomChannelFactory = Future<WebSocketChannel> Function(Uri uri, String origin);

/// WebSocket service communicating with uburoom's `/watch-socket` endpoint.
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
  final Map<int, int> _clockSentAt = {};
  Completer<void>? _authCompleter;

  // ignore: close_sinks
  final _connectionStateController = StreamController<UburoomConnectionState>.broadcast();
  final _identityController = StreamController<Map<String, dynamic>>.broadcast();
  final _roomsController = StreamController<dynamic>.broadcast();
  final _roomStateController = StreamController<UburoomRoomStatePush>.broadcast();
  final _roomKickedController = StreamController<String>.broadcast();
  final _unavailableController = StreamController<dynamic>.broadcast();

  Stream<UburoomConnectionState> get connectionStateStream => _connectionStateController.stream;
  Stream<Map<String, dynamic>> get identityStream => _identityController.stream;
  Stream<dynamic> get roomsStream => _roomsController.stream;
  Stream<UburoomRoomStatePush> get roomStateStream => _roomStateController.stream;
  Stream<String> get roomKickedStream => _roomKickedController.stream;
  Stream<dynamic> get unavailableStream => _unavailableController.stream;

  void _setState(UburoomConnectionState newState) {
    if (_state == newState) return;
    _state = newState;
    _connectionStateController.add(newState);
  }

  /// Connects to the uburoom server and authenticates with [token].
  Future<void> connect({required String serverUrl, required String token}) async {
    _explicitlyClosed = false;
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
      _channel = channel;
      _subscription = channel.stream.listen(_onMessage, onError: _onError, onDone: _onDone, cancelOnError: true);

      _setState(UburoomConnectionState.authenticating);
      _authCompleter = Completer<void>();
      _sendRaw({'type': 'auth', 'token': _token});

      await _authCompleter!.future.timeout(const Duration(seconds: 5));

      _reconnectAttempts = 0;
      _setState(UburoomConnectionState.connected);
      _startClockLoop();
    } catch (error, stackTrace) {
      appLogger.w('UburoomSocketService: connect/auth failed: $error', error: error, stackTrace: stackTrace);
      _cleanupChannel();
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
    final now = DateTime.now().millisecondsSinceEpoch;
    _clockSentAt[id] = now;
    // Clean up stale clock pings older than 10 seconds
    _clockSentAt.removeWhere((_, sendAt) => now - sendAt > 10000);
    _sendRaw({'type': 'clock', 'id': id});
  }

  /// Sends a request over the WebSocket multiplexer and awaits the response.
  Future<UburoomResponse> sendRequest(String path, [Map<String, dynamic>? data]) {
    if (!isConnected) {
      return Future.error(const SocketException('Uburoom socket is not connected'));
    }
    final id = ++_seq;
    final completer = Completer<UburoomResponse>();
    _inflight[id] = completer;

    final Map<String, dynamic> msg = {'type': 'request', 'id': id, 'path': path};
    if (data != null) msg['data'] = data;

    _sendRaw(msg);

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _inflight.remove(id);
        throw TimeoutException('Request $path timed out', const Duration(seconds: 10));
      },
    );
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
  }) {
    if (!isConnected) return;
    final Map<String, dynamic> msg = {
      'type': 'sync-quality',
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
        case 'auth-ok':
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
              final serverNow = json['serverNow'] as int? ?? DateTime.now().millisecondsSinceEpoch;
              clockSync.addSample(
                localSendAt: sendAt,
                serverReceivedAt: timing?['serverReceivedAt'] as int? ?? serverNow,
                serverSentAt: timing?['serverSentAt'] as int? ?? serverNow,
                serverProcessingMs: (timing?['serverProcessingMs'] as num?)?.toDouble() ?? 0.0,
                localReceiveAt: DateTime.now().millisecondsSinceEpoch,
                clockEpoch: timing?['clockEpoch'] ?? 0,
              );
            }
          }
          break;
        case 'response':
          final id = json['id'] as int?;
          if (id != null) {
            final completer = _inflight.remove(id);
            completer?.complete(UburoomResponse(id: id, status: json['status'] as int? ?? 200, value: json['value']));
          }
          break;
        case 'identity':
          final val = json['value'];
          if (val is Map<String, dynamic>) {
            _identityController.add(val);
          }
          break;
        case 'rooms':
          _roomsController.add(json['rooms'] ?? json['value']?['rooms']);
          break;
        case 'state':
          _roomStateController.add(
            UburoomRoomStatePush(
              path: json['path'] as String? ?? '',
              status: json['status'] as int? ?? 200,
              value: json['value'],
            ),
          );
          break;
        case 'room-kicked':
          _roomKickedController.add(json['roomId'] as String? ?? '');
          break;
        case 'unavailable':
          _unavailableController.add(json['value']);
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
    if (!_explicitlyClosed && _serverUrl != null && _token != null) {
      _scheduleReconnect();
    } else {
      _setState(UburoomConnectionState.disconnected);
    }
  }

  void _scheduleReconnect() {
    _setState(UburoomConnectionState.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    final delaySeconds = math.min(10, 1 << math.min(4, _reconnectAttempts - 1));
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!_explicitlyClosed) {
        unawaited(_performConnect());
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
