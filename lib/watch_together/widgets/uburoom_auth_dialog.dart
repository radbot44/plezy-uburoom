import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../utils/dialogs.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/dialog_action_button.dart';
import '../../widgets/loading_indicator_box.dart';
import '../services/uburoom_auth_service.dart';
import '../providers/watch_together_provider.dart';

/// Opens the dialog to authenticate against an uburoom server using browser handoff
/// or manual token entry.
Future<bool> showUburoomAuthDialog(BuildContext context, {UburoomAuthService? authService}) async {
  final provider = context.read<WatchTogetherProvider?>();
  final result =
      await showScopedDialog<bool>(
        context: context,
        builder: (_) => UburoomAuthDialog(authService: authService),
      ) ??
      false;
  if (context.mounted) provider?.refreshServerSettings();
  return result;
}

class UburoomAuthDialog extends StatefulWidget {
  const UburoomAuthDialog({super.key, this.authService});

  final UburoomAuthService? authService;

  @override
  State<UburoomAuthDialog> createState() => _UburoomAuthDialogState();
}

class _UburoomAuthDialogState extends State<UburoomAuthDialog> {
  late final UburoomAuthService _authService;
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;

  final _urlFocusNode = FocusNode(debugLabel: 'UburoomServerUrl');
  final _tokenFocusNode = FocusNode(debugLabel: 'UburoomManualToken');
  final _actionFocusNode = FocusNode(debugLabel: 'UburoomAction');

  bool _loading = true;
  bool _connected = false;
  bool _polling = false;
  bool _cancelled = false;
  bool _showManualEntry = false;
  String? _currentUrl;
  String? _error;
  NativeHandoffSession? _activeSession;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? UburoomAuthService();
    _urlController = TextEditingController();
    _tokenController = TextEditingController();
    _loadState();
  }

  @override
  void dispose() {
    _cancelled = true;
    _urlController.dispose();
    _tokenController.dispose();
    _urlFocusNode.dispose();
    _tokenFocusNode.dispose();
    _actionFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadState() async {
    final url = _authService.serverUrl;
    final token = await _authService.getToken();
    if (!mounted) return;
    setState(() {
      _currentUrl = url;
      _connected = url != null && token != null;
      if (url != null) _urlController.text = url;
      _loading = false;
    });
  }

  Future<void> _disconnect() async {
    setState(() => _loading = true);
    await _authService.clearCredentials();
    if (!mounted) return;
    setState(() {
      _connected = false;
      _currentUrl = null;
      _urlController.clear();
      _tokenController.clear();
      _loading = false;
      _error = null;
    });
  }

  Future<void> _startBrowserHandoff() async {
    final rawUrl = _urlController.text.trim();
    if (rawUrl.isEmpty) {
      setState(() => _error = 'Please enter an uburoom server URL');
      return;
    }

    setState(() {
      _polling = true;
      _cancelled = false;
      _error = null;
    });

    try {
      final session = await _authService.startBrowserHandoff(rawUrl);
      if (!mounted || _cancelled) return;

      setState(() => _activeSession = session);

      final token = await _authService.pollHandoff(session);
      if (!mounted || _cancelled) return;

      if (token != null && token.isNotEmpty) {
        await _authService.saveCredentials(serverUrl: session.serverUrl, token: token);
        if (mounted) Navigator.of(context).pop(true);
      } else {
        setState(() {
          _polling = false;
          _activeSession = null;
          _error = 'Handoff timed out or was rejected';
        });
      }
    } catch (e) {
      if (!mounted || _cancelled) return;
      setState(() {
        _polling = false;
        _activeSession = null;
        _error = 'Handoff failed: ${e.toString()}';
      });
    }
  }

  void _cancelPolling() {
    setState(() {
      _cancelled = true;
      _polling = false;
      _activeSession = null;
    });
  }

  Future<void> _saveManualToken() async {
    final rawUrl = _urlController.text.trim();
    final rawToken = _tokenController.text.trim();

    if (rawUrl.isEmpty) {
      setState(() => _error = 'Please enter an uburoom server URL');
      return;
    }

    final tokenRegex = RegExp(r'^[a-fA-F0-9]{64}$');
    if (!tokenRegex.hasMatch(rawToken)) {
      setState(() => _error = 'Token must be a 64-character hexadecimal string');
      return;
    }

    try {
      await _authService.saveCredentials(serverUrl: rawUrl, token: rawToken);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = 'Failed to save token: $e');
    }
  }

  Future<void> _pasteToken() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isNotEmpty) {
      _tokenController.text = text;
      setState(() => _error = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const AlertDialog(
        content: SizedBox(height: 120, child: Center(child: LoadingIndicatorBox(size: 32))),
      );
    }

    return AlertDialog(
      title: Row(
        children: [const AppIcon(Symbols.dns_rounded), const SizedBox(width: 8), const Text('Uburoom Server')],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_connected) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withAlpha(128),
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                  ),
                  child: Row(
                    children: [
                      AppIcon(Symbols.check_circle_rounded, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Connected',
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              _currentUrl ?? '',
                              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ] else if (_polling) ...[
                const SizedBox(height: 8),
                const Center(child: LoadingIndicatorBox(size: 36)),
                const SizedBox(height: 16),
                Text('Approving in browser...', style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  'Confirm this code matches in your browser:',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                if (_activeSession != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: const BorderRadius.all(Radius.circular(10)),
                    ),
                    child: Center(
                      child: Text(
                        _activeSession!.displayCode,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontFamily: 'monospace',
                          letterSpacing: _activeSession!.verification != null ? 6 : 2,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
              ] else ...[
                FocusableTextField(
                  controller: _urlController,
                  focusNode: _urlFocusNode,
                  decoration: InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'https://uburoom.example.com',
                    prefixIcon: const AppIcon(Symbols.link_rounded),
                  ),
                  textInputAction: TextInputAction.next,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  focusNode: _actionFocusNode,
                  icon: const AppIcon(Symbols.open_in_browser_rounded),
                  label: const Text('Sign in with Browser'),
                  onPressed: _startBrowserHandoff,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: AppIcon(
                      _showManualEntry ? Symbols.expand_less_rounded : Symbols.expand_more_rounded,
                      size: 20,
                    ),
                    label: Text(_showManualEntry ? 'Hide manual token' : 'Or enter Bearer token manually'),
                    onPressed: () {
                      setState(() => _showManualEntry = !_showManualEntry);
                      if (_showManualEntry) {
                        _tokenFocusNode.requestFocus();
                      }
                    },
                  ),
                ),
                if (_showManualEntry) ...[
                  const SizedBox(height: 8),
                  FocusableTextField(
                    controller: _tokenController,
                    focusNode: _tokenFocusNode,
                    decoration: InputDecoration(
                      labelText: 'Bearer Token',
                      hintText: '64-character hexadecimal token',
                      suffixIcon: IconButton(
                        icon: const AppIcon(Symbols.content_paste_rounded),
                        tooltip: 'Paste from clipboard',
                        onPressed: _pasteToken,
                      ),
                    ),
                    textInputAction: TextInputAction.done,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _saveManualToken(),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(onPressed: _saveManualToken, child: const Text('Save Token')),
                ],
              ],
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                Text(error, style: TextStyle(color: theme.colorScheme.error, fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (_connected) DialogActionButton(onPressed: _disconnect, label: 'Disconnect'),
        if (_polling)
          DialogActionButton(onPressed: _cancelPolling, label: t.common.cancel)
        else
          DialogActionButton(onPressed: () => Navigator.of(context).pop(false), label: t.common.close),
      ],
    );
  }
}
