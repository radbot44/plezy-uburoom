import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/watch_together_provider.dart';
import 'join_session_dialog.dart';
import 'uburoom_auth_dialog.dart';

/// Server-owned rooms, independent of Open Watch Party relays and codes.
class UburoomLobby extends StatefulWidget {
  const UburoomLobby({super.key});

  @override
  State<UburoomLobby> createState() => _UburoomLobbyState();
}

class _UburoomLobbyState extends State<UburoomLobby> {
  List<Map<String, dynamic>> _rooms = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rooms = await context.read<WatchTogetherProvider>().listUburoomRooms();
      if (mounted) setState(() => _rooms = rooms);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _errorText(Object error) => error is UburoomRoomException
      ? error.message
      : 'Could not reach uburoom. Check your connection and sign in again if needed.';

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    var roomName = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create uburoom room'),
        content: TextField(
          onChanged: (value) => roomName = value,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Room name'),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (roomName.trim().isNotEmpty) Navigator.pop(context, roomName.trim());
            },
            child: const Text('Create Room'),
          ),
        ],
      ),
    );
    if (!mounted || name == null) return;
    await _run(() async {
      await context.read<WatchTogetherProvider>().createRoom(name: name);
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<WatchTogetherProvider>();
    final disabled = _busy || _loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Uburoom', style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(provider.uburoomServerUrl ?? '', textAlign: TextAlign.center),
        const SizedBox(height: 24),
        FilledButton(onPressed: disabled ? null : _create, child: const Text('Create Room')),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: disabled ? null : () => showJoinRoomDialog(context),
          child: const Text('Join by name or link'),
        ),
        TextButton(
          onPressed: _busy ? null : () => showUburoomAuthDialog(context),
          child: const Text('Uburoom Server Settings'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Row(
          children: [
            const Expanded(child: Text('Rooms')),
            TextButton(onPressed: disabled ? null : _refresh, child: const Text('Refresh')),
          ],
        ),
        if (disabled) const Center(child: CircularProgressIndicator()),
        if (!_loading && _error == null && _rooms.isEmpty)
          const Text('No rooms available. Create a room to get started.'),
        for (final room in _rooms)
          Card(
            child: ListTile(
              title: Text(room['name']?.toString() ?? 'Unnamed room'),
              subtitle: Text('${room['active'] == false ? 'Saved room' : 'Active room'} · ${room['id']}'),
              trailing: Text(room['active'] == false ? 'Reopen' : 'Join'),
              enabled: !disabled,
              onTap: disabled ? null : () => _run(() => provider.openUburoomRoom(room)),
            ),
          ),
      ],
    );
  }
}
