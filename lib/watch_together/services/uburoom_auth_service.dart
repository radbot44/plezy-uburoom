import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../services/credential_vault.dart';
import '../../services/settings_service.dart';
import '../../utils/app_logger.dart';

class NativeHandoffSession {
  const NativeHandoffSession({
    required this.serverUrl,
    required this.handoffId,
    required this.code,
    required this.proof,
    required this.verificationUrl,
  });

  final String serverUrl;
  final String handoffId;
  final String code;
  final String proof;
  final String verificationUrl;
}

/// Manages authentication against an uburoom server using either browser handoff (Option 1A)
/// or direct token entry (Option 1B).
class UburoomAuthService {
  UburoomAuthService({this.settingsService, http.Client? httpClient, this.urlLauncher})
    : _client = httpClient ?? http.Client();

  final SettingsService? settingsService;
  final http.Client _client;
  final Future<bool> Function(Uri)? urlLauncher;

  SettingsService? get _settings {
    if (settingsService != null) return settingsService;
    try {
      return SettingsService.instance;
    } catch (_) {
      return null;
    }
  }

  String? get serverUrl => _settings?.read(SettingsService.uburoomServerUrl);

  Future<String?> getToken() async {
    final settings = _settings;
    if (settings == null) return null;
    final protected = settings.read(SettingsService.uburoomToken);
    if (protected == null || protected.isEmpty) return null;
    return await CredentialVault.reveal(protected);
  }

  Future<void> saveCredentials({required String serverUrl, required String token}) async {
    final settings = _settings;
    if (settings == null) return;
    final normalized = normalizeServerUrl(serverUrl);
    final protected = await CredentialVault.protect(token.trim());
    await settings.write(SettingsService.uburoomServerUrl, normalized);
    await settings.write(SettingsService.uburoomToken, protected);
  }

  Future<void> clearCredentials() async {
    final settings = _settings;
    if (settings == null) return;
    await settings.write(SettingsService.uburoomServerUrl, null);
    await settings.write(SettingsService.uburoomToken, null);
  }

  /// Starts the browser handoff flow by requesting a handoff code from the uburoom server
  /// and launching the system browser for the user to approve the companion client.
  Future<NativeHandoffSession> startBrowserHandoff(String serverUrl) async {
    final normalized = normalizeServerUrl(serverUrl);
    final uri = Uri.parse('$normalized/api/watch/handoff/native/start');
    final response = await _client.post(uri);
    if (response.statusCode != 200) {
      throw HttpException('Failed to start native handoff (${response.statusCode}): ${response.body}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final session = NativeHandoffSession(
      serverUrl: normalized,
      handoffId: (json['id'] ?? json['handoff']) as String,
      code: json['code'] as String,
      proof: (json['proof'] as String?) ?? '',
      verificationUrl: (json['url'] ?? json['verificationUrl']) as String,
    );

    final launchUri = Uri.parse(session.verificationUrl);
    if (urlLauncher != null) {
      await urlLauncher!(launchUri);
    } else {
      try {
        if (await canLaunchUrl(launchUri)) {
          await launchUrl(launchUri, mode: LaunchMode.externalApplication);
        } else {
          appLogger.w('UburoomAuthService: cannot launch verification URL: $launchUri');
        }
      } catch (e) {
        appLogger.w('UburoomAuthService: launchUrl failed: $e');
      }
    }

    return session;
  }

  /// Polls the uburoom server until the user approves the companion client or [timeout] passes.
  Future<String?> pollHandoff(
    NativeHandoffSession session, {
    Duration timeout = const Duration(minutes: 5),
    Duration interval = const Duration(milliseconds: 1500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    final uri = Uri.parse('${session.serverUrl}/api/watch/handoff/native/poll');

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
      try {
        final response = await _client.post(
          uri,
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'id': session.handoffId, 'proof': session.proof}),
        );
        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final token = json['token'] as String?;
          if (token != null && token.isNotEmpty) {
            await saveCredentials(serverUrl: session.serverUrl, token: token);
            return token;
          }
        } else if (response.statusCode == 202) {
          continue;
        } else if (response.statusCode == 404 || response.statusCode == 410) {
          throw const HttpException('Handoff expired or was revoked');
        }
      } catch (e) {
        if (e is HttpException) rethrow;
        appLogger.d('UburoomAuthService: poll error: $e');
      }
    }
    throw TimeoutException('Browser handoff timed out waiting for approval');
  }

  static String normalizeServerUrl(String input) {
    var raw = input.trim();
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'https://$raw';
    }
    final uri = Uri.parse(raw);
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
  }
}
