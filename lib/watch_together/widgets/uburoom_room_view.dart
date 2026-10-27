import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_icon.dart';
import '../models/uburoom_room_state.dart';
import '../providers/watch_together_provider.dart';
import 'watch_room_sections.dart';

/// Native Plezy-style room view for an active uburoom session.
class UburoomRoomView extends StatelessWidget {
  const UburoomRoomView({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WatchTogetherProvider>();
    final state = provider.uburoomState;
    if (state == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final theme = Theme.of(context);
    final isHost = state.isHost || state.canManage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (provider.isReconnecting) const WatchReconnectingBanner(),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const AppIcon(Symbols.meeting_room_rounded, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.roomName.isNotEmpty ? state.roomName : state.id,
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          state.id,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            color: theme.colorScheme.outline,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Media', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
              const SizedBox(height: 8),
              if (state.hasMedia) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppIcon(
                      state.paused ? Symbols.pause_circle_rounded : Symbols.play_circle_rounded,
                      size: 32,
                      fill: 1,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(state.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                          if (state.subtitle.isNotEmpty)
                            Text(
                              state.subtitle,
                              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          const SizedBox(height: 4),
                          Text(
                            _formatPlaybackTimeline(state),
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (provider.canJoinPlayback)
                      FilledButton.icon(
                        icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1),
                        label: const Text('Join Playback'),
                        onPressed: () => unawaited(provider.joinPlayback()),
                      ),
                    if (state.canPlayback)
                      OutlinedButton.icon(
                        icon: AppIcon(state.paused ? Symbols.play_arrow_rounded : Symbols.pause_rounded),
                        label: Text(state.paused ? 'Play' : 'Pause'),
                        onPressed: () {
                          if (state.paused) {
                            provider.play();
                          } else {
                            provider.pause();
                          }
                        },
                      ),
                  ],
                ),
              ] else ...[
                Row(
                  children: [
                    AppIcon(Symbols.movie_rounded, size: 32, color: theme.colorScheme.outline),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Nothing playing', style: theme.textTheme.titleMedium),
                          Text(
                            'Choose something to watch in uburoom…',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        _Card(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Participants (${state.participants.length})',
                        style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (state.participants.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('No participants listed'),
                )
              else
                for (final p in state.participants) _ParticipantTile(participant: p, viewerId: provider.viewerId),
            ],
          ),
        ),
        const SizedBox(height: 16),
        WatchButtonRow(
          alignment: WrapAlignment.center,
          children: [
            WatchButton(
              label: t.watchTogether.leaveRoom,
              icon: Symbols.logout_rounded,
              onPressed: () => unawaited(confirmLeaveRoom(context)),
            ),
            if (isHost)
              WatchButton(
                label: t.watchTogether.endRoom,
                icon: Symbols.cancel_rounded,
                style: WatchButtonStyle.tonal,
                onPressed: () => unawaited(confirmEndRoom(context)),
              ),
          ],
        ),
      ],
    );
  }

  static String _formatPlaybackTimeline(UburoomRoomState state) {
    final pos = formatDurationTimestamp(Duration(seconds: state.positionSeconds.round()));
    final dur = state.durationSeconds > 0
        ? formatDurationTimestamp(Duration(seconds: state.durationSeconds.round()))
        : null;
    final status = state.waitingForReady ? 'Waiting for ready' : (state.paused ? 'Paused' : 'Playing');
    final delivery = state.deliveryMode == 'local' ? ' · Local file' : '';
    return dur != null ? '$status · $pos / $dur$delivery' : '$status · $pos$delivery';
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({required this.participant, required this.viewerId});

  final UburoomParticipant participant;
  final String viewerId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMe = participant.id == viewerId;
    final isOnline = participant.present;

    final details = <String>[
      isOnline ? 'Connected' : 'Offline',
      if (participant.syncLevel != null) 'Sync: ${participant.syncLevel}',
      if (participant.syncStatus != null && participant.syncStatus != 'playing' && participant.syncStatus != 'known')
        participant.syncStatus!,
    ].join(' · ');

    return ListTile(
      leading: AppIcon(
        isOnline ? Symbols.person_rounded : Symbols.person_off_rounded,
        fill: 1,
        color: isOnline ? theme.colorScheme.primary : theme.colorScheme.outline,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              isMe ? '${participant.name} (You)' : participant.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: isMe ? const TextStyle(fontWeight: FontWeight.bold) : null,
            ),
          ),
          if (participant.isHost) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Host',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onPrimaryContainer),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(details, style: theme.textTheme.bodySmall),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 12),
    child: Padding(padding: padding, child: child),
  );
}
