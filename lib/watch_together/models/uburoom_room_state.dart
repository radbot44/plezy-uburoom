import 'package:flutter/foundation.dart';

/// A viewer or member participating in an uburoom room.
@immutable
class UburoomParticipant {
  const UburoomParticipant({
    required this.id,
    required this.name,
    required this.role,
    required this.isHost,
    required this.present,
    this.syncStatus,
    this.syncLevel,
  });

  final String id;
  final String name;
  final String role;
  final bool isHost;
  bool get host => isHost;
  final bool present;
  bool get connected => present;
  final String? syncStatus;
  final String? syncLevel;

  factory UburoomParticipant.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? json['userId'])?.toString() ?? '';
    final name = (json['name'] ?? 'Viewer').toString();
    final role = (json['role'] ?? 'viewer').toString();
    final isHost = role == 'host' || role == 'creator' || json['isHost'] == true || json['explicitHost'] == true;
    final present = json['present'] != false;
    final syncQuality = json['syncQuality'] as Map<String, dynamic>?;
    return UburoomParticipant(
      id: id,
      name: name,
      role: role,
      isHost: isHost,
      present: present,
      syncStatus: syncQuality?['status']?.toString(),
      syncLevel: syncQuality?['level']?.toString(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UburoomParticipant &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          role == other.role &&
          isHost == other.isHost &&
          present == other.present &&
          syncStatus == other.syncStatus &&
          syncLevel == other.syncLevel;

  @override
  int get hashCode => Object.hash(id, name, role, isHost, present, syncStatus, syncLevel);
}

/// An immutable item queued or up next in an uburoom room.
@immutable
class UburoomQueueItem {
  const UburoomQueueItem({
    required this.id,
    required this.mediaId,
    required this.serverId,
    required this.title,
    this.subtitle = '',
    this.type = 'movie',
    this.durationSeconds = 0.0,
    this.addedBy,
  });

  final String id;
  final String mediaId;
  final String serverId;
  final String title;
  final String subtitle;
  final String type;
  final double durationSeconds;
  final String? addedBy;

  factory UburoomQueueItem.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? json['entryId'] ?? json['mediaId'] ?? '').toString();
    final mediaId = (json['mediaId'] ?? json['id'] ?? '').toString();
    final serverId = (json['serverId'] ?? (json['media'] is Map ? (json['media'] as Map)['serverId'] : null) ?? '')
        .toString();
    final title = (json['title'] ?? (json['media'] is Map ? (json['media'] as Map)['title'] : null) ?? '').toString();
    final subtitle =
        (json['subtitle'] ??
                (json['type'] == 'episode'
                    ? [
                        json['grandparentTitle'],
                        json['parentTitle'],
                      ].whereType<String>().where((s) => s.isNotEmpty).join(' · ')
                    : json['parentTitle']) ??
                '')
            .toString();
    final type = (json['type'] ?? 'movie').toString();
    final num? rawDuration =
        (json['durationSeconds'] is num
            ? json['durationSeconds'] as num
            : (json['durationSeconds'] != null ? num.tryParse(json['durationSeconds'].toString()) : null)) ??
        (json['duration'] is num
            ? json['duration'] as num
            : (json['duration'] != null ? num.tryParse(json['duration'].toString()) : null));
    final durationSeconds = rawDuration?.toDouble() ?? 0.0;
    final addedBy = (json['addedBy'] ?? json['userId'])?.toString();

    return UburoomQueueItem(
      id: id,
      mediaId: mediaId,
      serverId: serverId,
      title: title,
      subtitle: subtitle,
      type: type,
      durationSeconds: durationSeconds,
      addedBy: addedBy,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'mediaId': mediaId,
    'serverId': serverId,
    'title': title,
    'subtitle': subtitle,
    'type': type,
    'durationSeconds': durationSeconds,
    if (addedBy != null) 'addedBy': addedBy,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UburoomQueueItem &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          mediaId == other.mediaId &&
          serverId == other.serverId &&
          title == other.title &&
          subtitle == other.subtitle &&
          type == other.type &&
          durationSeconds == other.durationSeconds &&
          addedBy == other.addedBy;

  @override
  int get hashCode => Object.hash(id, mediaId, serverId, title, subtitle, type, durationSeconds, addedBy);

  @override
  String toString() =>
      'UburoomQueueItem(id: $id, mediaId: $mediaId, serverId: $serverId, title: $title, subtitle: $subtitle, type: $type, durationSeconds: $durationSeconds, addedBy: $addedBy)';
}

/// An immutable stream audio or subtitle track offered in an uburoom room.
@immutable
class UburoomStreamTrack {
  const UburoomStreamTrack({
    required this.id,
    required this.title,
    this.language,
    this.codec,
    this.selected = false,
    this.delivery,
  });

  final String id;
  final String title;
  final String? language;
  final String? codec;
  final bool selected;
  final String? delivery;

  factory UburoomStreamTrack.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? json['streamId'] ?? '').toString();
    final title = (json['label'] ?? json['title'] ?? json['language'] ?? 'Track').toString();
    final language = json['language']?.toString();
    final codec = json['codec']?.toString();
    final selected = json['selected'] == true;
    final delivery = json['delivery']?.toString();

    return UburoomStreamTrack(
      id: id,
      title: title,
      language: language,
      codec: codec,
      selected: selected,
      delivery: delivery,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (language != null) 'language': language,
    if (codec != null) 'codec': codec,
    'selected': selected,
    if (delivery != null) 'delivery': delivery,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UburoomStreamTrack &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          title == other.title &&
          language == other.language &&
          codec == other.codec &&
          selected == other.selected &&
          delivery == other.delivery;

  @override
  int get hashCode => Object.hash(id, title, language, codec, selected, delivery);

  @override
  String toString() =>
      'UburoomStreamTrack(id: $id, title: $title, language: $language, codec: $codec, selected: $selected, delivery: $delivery)';
}

/// Server-authoritative room and playback state for an uburoom room.
@immutable
class UburoomRoomState {
  const UburoomRoomState({
    required this.id,
    required this.roomName,
    required this.epoch,
    required this.revision,
    this.mediaId,
    required this.title,
    required this.subtitle,
    this.mediaUrl,
    this.directHls,
    this.format,
    this.mediaVersion,
    this.streamVersion,
    this.readinessVersion,
    this.waitingForReady = false,
    this.positionSeconds = 0.0,
    this.durationSeconds = 0.0,
    this.paused = true,
    this.startAt,
    this.pauseAt,
    this.serverNow,
    this.isHost = false,
    this.canPlayback = false,
    this.canManage = false,
    this.durable = false,
    this.viewersCount = 0,
    this.participants = const [],
    this.deliveryMode = 'auto',
    this.directDelivery = false,
    this.subtitleUrl,
    this.visibility = 'public',
    this.autoQueue = false,
    this.queue = const [],
    this.queueCount = 0,
    this.queueRevision = 0,
    this.hasNext = false,
    this.autoQueueMode = 'off',
    this.currentItem,
    this.nextItem,
    this.qualityLabels = const {},
    this.qualityOptions = const [],
    this.selectedQuality,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
  });

  final String id;
  final String roomName;
  final String epoch;
  final int revision;
  final String? mediaId;
  final String title;
  final String subtitle;
  final String? mediaUrl;
  final dynamic directHls;
  final String? format;
  final String? mediaVersion;
  final String? streamVersion;
  final String? readinessVersion;
  final bool waitingForReady;
  final double positionSeconds;
  final double durationSeconds;
  final bool paused;
  final int? startAt;
  final int? pauseAt;
  final int? serverNow;
  final bool isHost;
  final bool canPlayback;
  final bool canManage;
  final bool durable;
  final int viewersCount;
  final List<UburoomParticipant> participants;
  final String deliveryMode;
  final bool directDelivery;
  final String? subtitleUrl;
  final String visibility;
  final bool autoQueue;
  final List<UburoomQueueItem> queue;
  final int queueCount;
  final int queueRevision;
  final bool hasNext;
  final String autoQueueMode;
  final UburoomQueueItem? currentItem;
  final UburoomQueueItem? nextItem;
  final Map<String, String> qualityLabels;
  final List<String> qualityOptions;
  final String? selectedQuality;
  final List<UburoomStreamTrack> audioTracks;
  final List<UburoomStreamTrack> subtitleTracks;

  bool get hasMedia => mediaId != null && mediaId!.isNotEmpty;

  String? get resolvedStreamUrl =>
      mediaUrl ??
      (directHls is String ? directHls as String : (directHls is Map ? (directHls as Map)['url']?.toString() : null));

  factory UburoomRoomState.fromSnapshot(
    Map<String, dynamic> snapshot, {
    String deliveryMode = 'auto',
    List<UburoomQueueItem> queue = const [],
  }) {
    final stateObj = snapshot['state'] as Map<String, dynamic>?;
    final mediaId = snapshot['mediaId'] as String?;
    final title = snapshot['title'] as String? ?? 'Choose something to watch…';
    final subtitle = snapshot['subtitle'] as String? ?? '';
    final directHls = snapshot['directHls'];
    final mediaUrl = snapshot['mediaUrl'] as String?;
    final readinessVersion = snapshot['readinessVersion']?.toString();
    final waitingForReady = snapshot['waitingForReady'] == true;
    final epoch = snapshot['epoch'] as String? ?? '';
    final revision = snapshot['revision'] as int? ?? 0;
    final participants = (snapshot['participants'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(UburoomParticipant.fromJson)
        .toList();
    final directDelivery = snapshot['directDelivery'] == true;
    final subtitleUrl = snapshot['subtitleUrl'] as String?;
    final visibility = snapshot['visibility'] as String? ?? 'public';
    final summary = snapshot['queueSummary'] as Map<String, dynamic>? ?? const {};
    final auto = summary['autoQueue'] as Map<String, dynamic>? ?? const {};
    final autoQueueMode = auto['mode'] as String? ?? 'off';
    final qualities = (snapshot['qualities'] as List? ?? const []).whereType<Map<String, dynamic>>();
    final qualityLabels = {for (final q in qualities) q['id'] as String: q['label'] as String};
    final tracks = snapshot['tracks'] as Map<String, dynamic>? ?? const {};
    List<UburoomStreamTrack> readTracks(String kind, String selected) => (tracks[kind] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((track) => UburoomStreamTrack.fromJson({...track, 'selected': track['id'] == tracks[selected]}))
        .toList();
    UburoomQueueItem? entry(dynamic value) => value is Map<String, dynamic> ? UburoomQueueItem.fromJson(value) : null;
    return UburoomRoomState(
      id: snapshot['id']?.toString() ?? '',
      roomName: (snapshot['roomName'] as String?) ?? (snapshot['name'] as String?) ?? snapshot['id']?.toString() ?? '',
      epoch: epoch,
      revision: revision,
      mediaId: mediaId,
      title: title,
      subtitle: subtitle,
      mediaUrl: mediaUrl,
      directHls: directHls,
      format: snapshot['format'] as String?,
      mediaVersion: snapshot['mediaVersion']?.toString(),
      streamVersion: snapshot['streamVersion']?.toString(),
      readinessVersion: readinessVersion,
      waitingForReady: waitingForReady,
      positionSeconds: (stateObj?['position'] as num?)?.toDouble() ?? 0.0,
      durationSeconds: (stateObj?['duration'] as num?)?.toDouble() ?? 0.0,
      paused: stateObj?['paused'] as bool? ?? true,
      startAt: snapshot['startAt'] as int?,
      pauseAt: snapshot['pauseAt'] as int?,
      serverNow: snapshot['serverNow'] as int?,
      isHost: snapshot['isHost'] as bool? ?? false,
      canPlayback: snapshot['canPlayback'] as bool? ?? false,
      canManage: snapshot['canManage'] as bool? ?? false,
      durable: snapshot['durable'] == true,
      viewersCount: snapshot['viewers'] as int? ?? 0,
      participants: participants,
      deliveryMode: deliveryMode,
      directDelivery: directDelivery,
      subtitleUrl: subtitleUrl,
      visibility: visibility,
      autoQueue: autoQueueMode != 'off',
      autoQueueMode: autoQueueMode,
      queueCount: summary['pendingCount'] as int? ?? 0,
      queueRevision: summary['queueRevision'] as int? ?? 0,
      currentItem: entry(summary['current']),
      nextItem: entry(summary['next'] ?? auto['next']),
      hasNext: snapshot['hasNext'] == true,
      qualityLabels: qualityLabels,
      queue: queue,
      qualityOptions: qualityLabels.keys.toList(),
      selectedQuality: snapshot['quality'] as String?,
      audioTracks: readTracks('audio', 'audioId'),
      subtitleTracks: readTracks('subtitles', 'subtitleId'),
    );
  }
}
