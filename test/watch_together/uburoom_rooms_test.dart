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
      final track1 = UburoomStreamTrack.fromJson({
        'streamId': 'stream-fallback-id',
        'displayTitle': 'Commentary Track',
      });
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

  group('UburoomRoomState enhancements', () {
    test('supports directHls as a Map and falls back for mediaUrl and resolvedStreamUrl', () {
      final snapshot = {
        'id': 'room-uuid-1',
        'roomName': 'Watch Party',
        'epoch': 'epoch-1',
        'revision': 1,
        'directHls': {'url': '/api/watch/media/token/hls/master.m3u8', 'session': 'transcode-session-9'},
      };

      final state = UburoomRoomState.fromSnapshot(snapshot);
      expect(state.directHls, isA<Map<String, dynamic>>());
      expect((state.directHls as Map)['session'], 'transcode-session-9');
      expect(state.mediaUrl, '/api/watch/media/token/hls/master.m3u8');
      expect(state.resolvedStreamUrl, '/api/watch/media/token/hls/master.m3u8');
    });

    test('supports directHls as a String and falls back for mediaUrl and resolvedStreamUrl', () {
      final snapshot = {
        'id': 'room-uuid-2',
        'roomName': 'Direct Room',
        'epoch': 'epoch-2',
        'revision': 2,
        'directHls': 'https://stream.example/direct.m3u8',
      };

      final state = UburoomRoomState.fromSnapshot(snapshot);
      expect(state.directHls, 'https://stream.example/direct.m3u8');
      expect(state.mediaUrl, 'https://stream.example/direct.m3u8');
      expect(state.resolvedStreamUrl, 'https://stream.example/direct.m3u8');
    });

    test('mediaUrl takes precedence over directHls url', () {
      final snapshot = {
        'id': 'room-uuid-3',
        'epoch': 'epoch-3',
        'mediaUrl': '/api/watch/media/explicit/start',
        'directHls': {'url': '/api/watch/media/fallback/master.m3u8'},
      };

      final state = UburoomRoomState.fromSnapshot(snapshot);
      expect(state.mediaUrl, '/api/watch/media/explicit/start');
      expect(state.resolvedStreamUrl, '/api/watch/media/explicit/start');
    });

    test('parses directDelivery, subtitleUrl, and visibility with sensible defaults', () {
      // Default state
      final defaultState = UburoomRoomState.fromSnapshot({'id': 'room-default', 'epoch': 'ep-1'});
      expect(defaultState.directDelivery, isFalse);
      expect(defaultState.subtitleUrl, isNull);
      expect(defaultState.visibility, 'public');
      expect(defaultState.autoQueue, isFalse);
      expect(defaultState.queue, isEmpty);

      // Explicit values
      final explicitState = UburoomRoomState.fromSnapshot({
        'id': 'room-explicit',
        'epoch': 'ep-2',
        'directDelivery': true,
        'subtitleUrl': '/api/watch/media/grant/captions-v1',
        'visibility': 'unlisted',
        'autoQueue': true,
      });
      expect(explicitState.directDelivery, isTrue);
      expect(explicitState.subtitleUrl, '/api/watch/media/grant/captions-v1');
      expect(explicitState.visibility, 'unlisted');
      expect(explicitState.autoQueue, isTrue);
    });

    test('autoQueue parses from queue.auto Map', () {
      final state = UburoomRoomState.fromSnapshot({
        'id': 'room-auto',
        'epoch': 'ep-3',
        'queue': {'auto': true, 'items': <Map<String, dynamic>>[]},
      });
      expect(state.autoQueue, isTrue);
    });

    test('queue parses from List format', () {
      final state = UburoomRoomState.fromSnapshot({
        'id': 'room-q-list',
        'epoch': 'ep-4',
        'queue': [
          {'id': 'q-1', 'mediaId': '111', 'serverId': 'srv-1', 'title': 'Queue 1', 'durationSeconds': 120.0},
          {'id': 'q-2', 'mediaId': '222', 'serverId': 'srv-1', 'title': 'Queue 2', 'duration': 240.0},
        ],
      });

      expect(state.queue, hasLength(2));
      expect(state.queue[0].id, 'q-1');
      expect(state.queue[0].mediaId, '111');
      expect(state.queue[0].title, 'Queue 1');
      expect(state.queue[0].durationSeconds, 120.0);
      expect(state.queue[1].id, 'q-2');
      expect(state.queue[1].mediaId, '222');
      expect(state.queue[1].title, 'Queue 2');
      expect(state.queue[1].durationSeconds, 240.0);
    });

    test('queue parses from Map with items format', () {
      final state = UburoomRoomState.fromSnapshot({
        'id': 'room-q-map',
        'epoch': 'ep-5',
        'queue': {
          'auto': false,
          'items': [
            {'id': 'q-map-1', 'mediaId': '333', 'serverId': 'srv-2', 'title': 'Queue Map 1', 'durationSeconds': 360.0},
          ],
        },
      });

      expect(state.queue, hasLength(1));
      expect(state.queue[0].id, 'q-map-1');
      expect(state.queue[0].mediaId, '333');
      expect(state.queue[0].title, 'Queue Map 1');
    });

    test('queue parses from upNext when queue is absent', () {
      final state = UburoomRoomState.fromSnapshot({
        'id': 'room-upnext',
        'epoch': 'ep-6',
        'upNext': [
          {
            'id': 'upnext-1',
            'mediaId': '444',
            'serverId': 'srv-3',
            'title': 'Next Up Episode',
            'durationSeconds': 1500.0,
          },
        ],
      });

      expect(state.queue, hasLength(1));
      expect(state.queue[0].id, 'upnext-1');
      expect(state.queue[0].mediaId, '444');
      expect(state.queue[0].title, 'Next Up Episode');
      expect(state.queue[0].durationSeconds, 1500.0);
    });

    test('parses qualityOptions and selectedQuality from top-level snapshot', () {
      final state = UburoomRoomState.fromSnapshot({
        'id': 'room-qual-1',
        'epoch': 'ep-q1',
        'options': ['1080p', '720p', '480p'],
        'quality': '1080p',
      });
      expect(state.qualityOptions, ['1080p', '720p', '480p']);
      expect(state.selectedQuality, '1080p');
    });

    test('parses qualityOptions and selectedQuality from media and selection objects', () {
      final state = UburoomRoomState.fromSnapshot({
        'id': 'room-qual-2',
        'epoch': 'ep-q2',
        'media': {
          'options': ['4k', '1080p'],
        },
        'selection': {'quality': '4k'},
      });
      expect(state.qualityOptions, ['4k', '1080p']);
      expect(state.selectedQuality, '4k');
    });

    test('parses audioTracks and subtitleTracks from top-level audioStreams and subtitleStreams', () {
      final state = UburoomRoomState.fromSnapshot({
        'id': 'room-streams-1',
        'epoch': 'ep-s1',
        'audioStreams': [
          {'id': 'a-1', 'title': 'English Stereo', 'language': 'eng', 'codec': 'aac', 'selected': true},
        ],
        'subtitleStreams': [
          {'id': 's-1', 'title': 'English (SDH)', 'language': 'eng', 'codec': 'subrip', 'delivery': 'burn'},
        ],
      });

      expect(state.audioTracks, hasLength(1));
      expect(state.audioTracks.first.id, 'a-1');
      expect(state.audioTracks.first.title, 'English Stereo');
      expect(state.audioTracks.first.selected, isTrue);

      expect(state.subtitleTracks, hasLength(1));
      expect(state.subtitleTracks.first.id, 's-1');
      expect(state.subtitleTracks.first.title, 'English (SDH)');
      expect(state.subtitleTracks.first.delivery, 'burn');
    });

    test('parses audioTracks and subtitleTracks from snapshot streams map', () {
      final state = UburoomRoomState.fromSnapshot({
        'id': 'room-streams-2',
        'epoch': 'ep-s2',
        'streams': {
          'audio': [
            {'streamId': 'aud-nested', 'displayTitle': 'Surround 5.1'},
          ],
          'subtitle': [
            {'streamId': 'sub-nested', 'displayTitle': 'French Subtitles'},
          ],
        },
      });

      expect(state.audioTracks, hasLength(1));
      expect(state.audioTracks.first.id, 'aud-nested');
      expect(state.audioTracks.first.title, 'Surround 5.1');

      expect(state.subtitleTracks, hasLength(1));
      expect(state.subtitleTracks.first.id, 'sub-nested');
      expect(state.subtitleTracks.first.title, 'French Subtitles');
    });

    test('parses audioTracks and subtitleTracks from media object fallback', () {
      final state = UburoomRoomState.fromSnapshot({
        'id': 'room-streams-3',
        'epoch': 'ep-s3',
        'media': {
          'audioStreams': [
            {'id': 'aud-media', 'title': 'Default Track'},
          ],
          'subtitleStreams': [
            {'id': 'sub-media', 'title': 'Default Subs'},
          ],
        },
      });

      expect(state.audioTracks, hasLength(1));
      expect(state.audioTracks.first.id, 'aud-media');
      expect(state.subtitleTracks, hasLength(1));
      expect(state.subtitleTracks.first.id, 'sub-media');
    });

    test('defaults quality and track lists to empty and selectedQuality to null', () {
      final state = UburoomRoomState.fromSnapshot({'id': 'room-empty-tracks', 'epoch': 'ep-empty'});

      expect(state.qualityOptions, isEmpty);
      expect(state.selectedQuality, isNull);
      expect(state.audioTracks, isEmpty);
      expect(state.subtitleTracks, isEmpty);
    });
  });
}
