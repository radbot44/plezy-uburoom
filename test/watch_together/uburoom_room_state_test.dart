import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/watch_together/models/uburoom_room_state.dart';

void main() {
  test('parses merged v2 lanes: queue summary, offered qualities and selected tracks', () {
    final state = UburoomRoomState.fromSnapshot({
      'id': 'room',
      'epoch': 'epoch',
      'revision': 4,
      'roomName': 'Film night',
      'mediaId': '42:7',
      'title': 'Film',
      'subtitle': '2026',
      'viewers': 2,
      'state': {'position': 12.5, 'duration': 600.0, 'paused': false, 'volume': 80},
      'participants': [
        {'userId': 'person', 'name': 'Viewer', 'role': 'host', 'present': true},
      ],
      'hasNext': true,
      'queueSummary': {
        'pendingCount': 3,
        'queueRevision': 9,
        'current': {'id': 'entry-current', 'mediaId': '42:7', 'title': 'Film'},
        'next': {'id': 'entry-next', 'mediaId': '43', 'title': 'Next film'},
        'autoQueue': {'mode': 'following', 'next': null},
      },
      'qualities': [
        {'id': 'direct', 'label': 'Original'},
        {'id': '1080p8', 'label': '1080p · 8 Mbps'},
      ],
      'quality': '1080p8',
      'tracks': {
        'audioId': '22',
        'subtitleId': '33',
        'audio': [
          {'id': '21', 'label': 'English', 'selected': true},
          {'id': '22', 'label': 'French'},
        ],
        'subtitles': [
          {'id': '33', 'label': 'French SDH', 'codec': 'srt', 'delivery': 'text'},
        ],
      },
    });
    expect(state.mediaId, '42:7');
    expect(state.durationSeconds, 600);
    expect(state.viewersCount, 2);
    expect(state.participants.single.isHost, true);
    expect(state.queue, isEmpty); // Entries are a separate paged call.
    expect(state.queueCount, 3);
    expect(state.queueRevision, 9);
    expect(state.currentItem?.id, 'entry-current');
    expect(state.nextItem?.id, 'entry-next');
    expect(state.autoQueue, true);
    expect(state.autoQueueMode, 'following');
    expect(state.hasNext, true);
    expect(state.qualityOptions, ['direct', '1080p8']);
    expect(state.qualityLabels['1080p8'], '1080p · 8 Mbps');
    expect(state.selectedQuality, '1080p8');
    expect(state.audioTracks.where((t) => t.selected).single.id, '22');
    expect(state.subtitleTracks.single.title, 'French SDH');
    expect(state.subtitleTracks.single.selected, true);
  });
}
