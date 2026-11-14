import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/watch_together_provider.dart';

/// Personal choices come exclusively from this viewer's server catalog.
class UburoomViewerSettings extends StatelessWidget {
  const UburoomViewerSettings({super.key});
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WatchTogetherProvider>();
    final state = provider.uburoomState;
    if (state == null) return const SizedBox.shrink();
    Widget choice(String label, String? selected, Map<String, String> options, void Function(String) changed) =>
        DropdownButtonFormField<String>(
          initialValue: options.containsKey(selected) ? selected : null,
          key: ValueKey('$label:$selected:${options.keys.join(',')}'),
          decoration: InputDecoration(labelText: label),
          isExpanded: true,
          items: options.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
          onChanged: (value) {
            if (value != null) changed(value);
          },
        );
    return Column(
      children: [
        if (state.qualityOptions.isNotEmpty)
          choice(
            'Quality',
            state.selectedQuality,
            state.qualityLabels,
            (id) => unawaited(provider.setUburoomQuality(id)),
          ),
        if (state.audioTracks.isNotEmpty)
          choice('Audio', state.audioTracks.where((t) => t.selected).firstOrNull?.id, {
            for (final t in state.audioTracks) t.id: t.title,
          }, (id) => unawaited(provider.setUburoomTracks(audioId: id))),
        if (state.subtitleTracks.isNotEmpty)
          choice('Subtitles', state.subtitleTracks.where((t) => t.selected).firstOrNull?.id ?? 'off', {
            'off': 'Off',
            for (final t in state.subtitleTracks) t.id: t.title,
          }, (id) => unawaited(provider.setUburoomTracks(subtitleId: id))),
      ],
    );
  }
}
