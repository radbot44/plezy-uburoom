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
    this.rate = 1.0,
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
  final double rate;
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

  bool get hasMedia => mediaId != null && mediaId!.isNotEmpty;

  factory UburoomRoomState.fromSnapshot(Map<String, dynamic> snapshot, {String deliveryMode = 'auto'}) {
    final stateObj = snapshot['state'] as Map<String, dynamic>?;
    final mediaObj = snapshot['media'] as Map<String, dynamic>?;
    final mediaId = snapshot['mediaId']?.toString() ?? mediaObj?['id']?.toString();
    final title =
        (snapshot['title'] as String?) ??
        (mediaObj?['title'] as String?) ??
        (mediaId != null ? 'Selected Media' : 'Choose something to watch…');
    final subtitle = (snapshot['subtitle'] as String?) ?? '';
    final mediaUrl =
        (snapshot['mediaUrl'] as String?) ?? (snapshot['directHls'] is String ? snapshot['directHls'] as String : null);
    final directHls = snapshot['directHls'];
    final readinessVersion =
        snapshot['readinessVersion']?.toString() ??
        (snapshot['readiness'] as Map<String, dynamic>?)?['version']?.toString();
    final waitingForReady = snapshot['waitingForReady'] as bool? ?? false;
    final epoch = (snapshot['epoch'] ?? '').toString();
    final revision = snapshot['revision'] as int? ?? 1;

    final rawParticipants = snapshot['participants'] is List
        ? snapshot['participants'] as List
        : (snapshot['viewers'] is List ? snapshot['viewers'] as List : const []);
    final participants = rawParticipants
        .whereType<Map<String, dynamic>>()
        .map((p) => UburoomParticipant.fromJson(p))
        .toList();

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
      durationSeconds:
          (stateObj?['duration'] as num?)?.toDouble() ??
          ((mediaObj?['duration'] as num?) != null ? (mediaObj!['duration'] as num).toDouble() / 1000.0 : 0.0),
      paused: stateObj?['paused'] as bool? ?? true,
      rate: (stateObj?['rate'] as num?)?.toDouble() ?? 1.0,
      startAt: snapshot['startAt'] as int?,
      pauseAt: snapshot['pauseAt'] as int?,
      serverNow: snapshot['serverNow'] as int?,
      isHost: snapshot['isHost'] as bool? ?? false,
      canPlayback: snapshot['canPlayback'] as bool? ?? false,
      canManage: snapshot['canManage'] as bool? ?? false,
      durable: snapshot['durable'] == true || snapshot['saved'] == true,
      viewersCount: snapshot['viewers'] is int ? snapshot['viewers'] as int : participants.length,
      participants: participants,
      deliveryMode: deliveryMode,
    );
  }
}
