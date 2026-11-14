import 'uburoom_test_requests.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:plezy/watch_together/models/uburoom_room_state.dart';
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
  Future<UburoomResponse> request(
    Map<String, dynamic> message, {
    Duration timeout = const Duration(seconds: 12),
  }) async => framed(message, await answer(requestName(message), requestData(message)));

  /// Answers one request by its name (see uburoom_test_requests.dart).
  Future<UburoomResponse> answer(String name, [Map<String, dynamic>? data]) async {
    requests.add((name, data));
    if (name == 'rooms.create') {
      return UburoomResponse(
        id: 1,
        status: denyCreation ? 403 : 201,
        value: denyCreation ? {'error': 'Room creation is disabled in single-room mode'} : {'id': roomId},
      );
    }
    if (name == 'rooms.list') {
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
    if (name == 'rooms.saved') {
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
    if (name == 'room.reopen') {
      return const UburoomResponse(id: 1, status: 200, value: {'id': roomId});
    }
    if (name == 'join') {
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

  test('create asks the server for a room, then joins the returned UUID', () async {
    expect(await provider.createRoom(name: 'test'), roomId);
    expect(socket.requests.first.$1, 'rooms.create');
    expect(socket.requests.first.$2, {'name': 'test', 'visibility': 'public'});
    expect(socket.requests.last.$1, 'join');
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
    expect(socket.requests.map((request) => request.$1), contains('room.reopen'));
    expect(provider.roomCode, roomId);
  });

  test('ambiguous room names cannot select an arbitrary room', () async {
    socket.duplicateName = true;
    await expectLater(provider.joinRoom('test'), throwsA(isA<UburoomRoomException>()));
    expect(socket.requests.map((request) => request.$1).toSet(), {'rooms.list', 'rooms.saved'}, reason: 'only reads');
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

  group('UburoomQueueItem', () {
    test('fromJson parses standard fields and defaults correctly', () {
      final item = UburoomQueueItem.fromJson({
        'id': 'entry-42',
        'mediaId': 'plex-101',
        'serverId': 'server-alpha',
        'title': 'The Grand Adventure',
        'subtitle': 'Director\'s Cut',
        'type': 'movie',
        'durationSeconds': 7320.5,
        'addedBy': 'user-uuid-1',
      });

      expect(item.id, 'entry-42');
      expect(item.mediaId, 'plex-101');
      expect(item.serverId, 'server-alpha');
      expect(item.title, 'The Grand Adventure');
      expect(item.subtitle, 'Director\'s Cut');
      expect(item.type, 'movie');
      expect(item.durationSeconds, 7320.5);
      expect(item.addedBy, 'user-uuid-1');
    });

    test('fromJson supports fallback field names', () {
      final item = UburoomQueueItem.fromJson({
        'entryId': 'entry-99',
        'mediaId': 'plex-202',
        'serverId': 'server-beta',
        'title': 'Pilot',
        'parentTitle': 'Season 1',
        'type': 'episode',
        'duration': 2700,
        'userId': 'user-uuid-2',
      });

      expect(item.id, 'entry-99');
      expect(item.mediaId, 'plex-202');
      expect(item.serverId, 'server-beta');
      expect(item.title, 'Pilot');
      expect(item.subtitle, 'Season 1');
      expect(item.type, 'episode');
      expect(item.durationSeconds, 2700.0);
      expect(item.addedBy, 'user-uuid-2');
    });

    test('equality and hashCode compare field values', () {
      const item1 = UburoomQueueItem(
        id: 'item-1',
        mediaId: 'plex-1',
        serverId: 'srv-1',
        title: 'Title',
        subtitle: 'Sub',
        type: 'movie',
        durationSeconds: 120.0,
        addedBy: 'user-1',
      );
      const item2 = UburoomQueueItem(
        id: 'item-1',
        mediaId: 'plex-1',
        serverId: 'srv-1',
        title: 'Title',
        subtitle: 'Sub',
        type: 'movie',
        durationSeconds: 120.0,
        addedBy: 'user-1',
      );
      const itemDiff = UburoomQueueItem(id: 'item-2', mediaId: 'plex-1', serverId: 'srv-1', title: 'Title');

      expect(item1, equals(item2));
      expect(item1.hashCode, equals(item2.hashCode));
      expect(item1, isNot(equals(itemDiff)));
    });
  });

  group('UburoomStreamTrack', () {
    test('fromJson parses standard fields and defaults correctly', () {
      final track = UburoomStreamTrack.fromJson({
        'id': 'stream-1',
        'title': 'English (5.1 Surround)',
        'language': 'eng',
        'codec': 'eac3',
        'selected': true,
        'delivery': 'direct',
      });

      expect(track.id, 'stream-1');
      expect(track.title, 'English (5.1 Surround)');
      expect(track.language, 'eng');
      expect(track.codec, 'eac3');
      expect(track.selected, isTrue);
      expect(track.delivery, 'direct');
    });

    test('fromJson handles fallbacks for id, title, and selected', () {
      final track1 = UburoomStreamTrack.fromJson({'id': 'stream-fallback-id', 'label': 'Commentary Track'});
      expect(track1.id, 'stream-fallback-id');
      expect(track1.title, 'Commentary Track');
      expect(track1.selected, isFalse);
      expect(track1.language, isNull);
      expect(track1.codec, isNull);
      expect(track1.delivery, isNull);

      final track2 = UburoomStreamTrack.fromJson({'language': 'fra'});
      expect(track2.id, '');
      expect(track2.title, 'fra');

      final track3 = UburoomStreamTrack.fromJson({});
      expect(track3.id, '');
      expect(track3.title, 'Track');
      expect(track3.selected, isFalse);
    });

    test('toJson serializes fields correctly', () {
      const track = UburoomStreamTrack(
        id: 't-1',
        title: 'Spanish',
        language: 'spa',
        codec: 'aac',
        selected: false,
        delivery: 'hls',
      );
      expect(track.toJson(), {
        'id': 't-1',
        'title': 'Spanish',
        'language': 'spa',
        'codec': 'aac',
        'selected': false,
        'delivery': 'hls',
      });
    });

    test('equality and hashCode compare field values', () {
      const track1 = UburoomStreamTrack(
        id: 'track-1',
        title: 'Main Audio',
        language: 'en',
        codec: 'aac',
        selected: true,
        delivery: 'direct',
      );
      const track2 = UburoomStreamTrack(
        id: 'track-1',
        title: 'Main Audio',
        language: 'en',
        codec: 'aac',
        selected: true,
        delivery: 'direct',
      );
      const trackDiff = UburoomStreamTrack(id: 'track-2', title: 'Main Audio');

      expect(track1, equals(track2));
      expect(track1.hashCode, equals(track2.hashCode));
      expect(track1, isNot(equals(trackDiff)));
    });
  });
}
