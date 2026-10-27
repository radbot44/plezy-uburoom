import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:plezy/watch_together/widgets/uburoom_lobby.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/watch_together/services/uburoom_auth_service.dart';
import 'package:plezy/watch_together/services/uburoom_socket_service.dart';

const roomId = '12345678-abcd-1234-abcd-123456789abc';

class _Auth extends UburoomAuthService {
  @override
  String get serverUrl => 'https://watch.example';
  @override
  Future<String?> getToken() async => 'fixture-token';
}

class _Socket extends UburoomSocketService {
  final requests = <(String, Map<String, dynamic>?)>[];
  bool denyCreation = false;
  bool duplicateName = false;
  @override
  bool get isConnected => true;
  @override
  String get serverUrl => 'https://watch.example';
  @override
  String get token => 'fixture-token';
  @override
  Future<UburoomResponse> sendRequest(String path, [Map<String, dynamic>? data]) async {
    requests.add((path, data));
    if (path == '/api/watch/rooms' && data != null) {
      return UburoomResponse(
        id: 1,
        status: denyCreation ? 403 : 201,
        value: denyCreation ? {'error': 'Room creation is disabled in single-room mode'} : {'id': roomId},
      );
    }
    if (path == '/api/watch/rooms') {
      return UburoomResponse(
        id: 1,
        status: 200,
        value: {
          'rooms': [
            if (duplicateName) {'id': '22345678-abcd-1234-abcd-123456789abc', 'name': 'test'},
          ],
        },
      );
    }
    if (path.startsWith('/api/watch/rooms/saved')) {
      return const UburoomResponse(
        id: 1,
        status: 200,
        value: {
          'rooms': [
            {'id': roomId, 'name': 'test', 'active': false},
          ],
          'total': 1,
        },
      );
    }
    if (path == '/api/watch/rooms/$roomId/reopen') {
      return const UburoomResponse(id: 1, status: 200, value: {'id': roomId});
    }
    if (path.startsWith('/api/watch/rooms/$roomId?')) {
      return const UburoomResponse(
        id: 1,
        status: 200,
        value: {
          'viewers': 1,
          'participants': [
            {'id': 'fixture-user', 'name': 'Fixture host', 'role': 'creator', 'present': true},
          ],
          'epoch': 'fixture-epoch',
          'state': {'paused': true},
        },
      );
    }
    return const UburoomResponse(id: 1, status: 404, value: {'error': 'Room unavailable'});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Socket socket;
  late WatchTogetherProvider provider;
  setUp(() {
    socket = _Socket();
    provider = WatchTogetherProvider(socketService: socket, authService: _Auth());
  });
  tearDown(() => provider.dispose());

  test('create uses the uburoom mutation endpoint then subscribes to the returned UUID', () async {
    expect(await provider.createRoom(name: 'test'), roomId);
    expect(socket.requests.first.$1, '/api/watch/rooms');
    expect(socket.requests.first.$2, {'name': 'test', 'visibility': 'public'});
    expect(socket.requests.last.$1, startsWith('/api/watch/rooms/$roomId?viewer='));
    expect(provider.isUburoomSession, isTrue);
    expect(provider.formattedRoomCode, roomId);
    expect(provider.participants.single.name, 'Fixture host');
  });

  test('server creation errors remain uburoom errors, not invalid OWP codes', () async {
    socket.denyCreation = true;
    await expectLater(
      provider.createRoom(name: 'test'),
      throwsA(
        isA<UburoomRoomException>().having(
          (error) => error.message,
          'message',
          'Room creation is disabled in single-room mode',
        ),
      ),
    );
    expect(socket.requests, hasLength(1));
  });

  test('saved room names resolve to UUIDs and reopen before joining', () async {
    await provider.joinRoom('test');
    expect(socket.requests.map((request) => request.$1), contains('/api/watch/rooms/$roomId/reopen'));
    expect(provider.roomCode, roomId);
  });

  test('ambiguous room names cannot select an arbitrary room', () async {
    socket.duplicateName = true;
    await expectLater(provider.joinRoom('test'), throwsA(isA<UburoomRoomException>()));
    expect(socket.requests.every((request) => request.$2 == null), isTrue);
    expect(provider.isUburoomSession, isFalse);
  });
  testWidgets('uburoom lobby lists saved names and displays server creation errors', (tester) async {
    socket.denyCreation = true;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: UburoomLobby())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('test'), findsOneWidget);
    expect(find.text('Reopen'), findsOneWidget);
    await tester.tap(find.text('Create Room'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'new room');
    await tester.tap(find.widgetWithText(FilledButton, 'Create Room').last);
    await tester.pumpAndSettle();
    expect(find.text('Room creation is disabled in single-room mode'), findsOneWidget);
    expect(find.textContaining('6 letters'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
