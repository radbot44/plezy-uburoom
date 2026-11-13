import 'package:plezy/watch_together/services/uburoom_socket_service.dart';

/// How the uburoom test fakes name a request: its message type (`join`,
/// `command`, `ready`, `observe`, `leave`), or for a `call` its op
/// (`rooms.list`, `room.queue.command`, ...).
String requestName(Map<String, dynamic> message) =>
    message['type'] == 'call' ? message['op'] as String : message['type'] as String;

/// What a request carries: a call's `args`, an observation, a join's
/// preferences, or the message's own fields.
Map<String, dynamic>? requestData(Map<String, dynamic> message) {
  switch (message['type']) {
    case 'call':
      return message['args'] as Map<String, dynamic>?;
    case 'observe':
      return message['observation'] as Map<String, dynamic>?;
    case 'join':
      return message['preferences'] as Map<String, dynamic>?;
    default:
      return Map<String, dynamic>.from(message)
        ..remove('type')
        ..remove('roomId');
  }
}

/// A fake's answer as the server frames it: a successful `join` answers with the
/// tab's two lanes. Fakes answer a join with the room snapshot they mean; this
/// puts it in the `room` lane, beside a `viewer` lane for the same video.
UburoomResponse framed(Map<String, dynamic> message, UburoomResponse response) {
  final value = response.value;
  if (message['type'] != 'join' || !response.isSuccess || value is! Map || value.containsKey('room')) return response;
  return UburoomResponse(
    id: response.id,
    status: response.status,
    value: {
      'room': {'version': 1, 'state': value},
      'viewer': {
        'version': 1,
        'state': {'mediaVersion': value['mediaVersion']},
      },
    },
  );
}
