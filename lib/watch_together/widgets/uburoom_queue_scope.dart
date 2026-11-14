import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../providers/watch_together_provider.dart';

class UburoomQueueScope extends StatefulWidget {
  const UburoomQueueScope({super.key, required this.child});
  final Widget child;
  @override
  State<UburoomQueueScope> createState() => _UburoomQueueScopeState();
}

class _UburoomQueueScopeState extends State<UburoomQueueScope> {
  WatchTogetherProvider? _provider;
  bool _registered = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<WatchTogetherProvider>();
    if (identical(next, _provider)) return;
    if (_registered) _provider?.unwatchUburoomQueue();
    _registered = false;
    _provider = next;
    scheduleMicrotask(() {
      if (mounted && identical(next, _provider)) {
        _registered = true;
        next.watchUburoomQueue();
      }
    });
  }

  @override
  void dispose() {
    if (_registered) _provider?.unwatchUburoomQueue();
    _registered = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
