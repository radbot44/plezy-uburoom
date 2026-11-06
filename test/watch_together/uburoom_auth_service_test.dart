import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/watch_together/services/uburoom_auth_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settingsService;

  setUp(() async {
    resetSharedPreferencesForTest();
    settingsService = await SettingsService.getInstance();
  });

  group('UburoomAuthService', () {
    test('saveCredentials and getToken round trip through vault', () async {
      final authService = UburoomAuthService(settingsService: settingsService);

      expect(authService.serverUrl, isNull);
      expect(await authService.getToken(), isNull);

      await authService.saveCredentials(
        serverUrl: 'http://192.168.1.50:6767/',
        token: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );

      expect(authService.serverUrl, 'http://192.168.1.50:6767');
      final token = await authService.getToken();
      expect(token, '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');

      await authService.clearCredentials();
      expect(authService.serverUrl, isNull);
      expect(await authService.getToken(), isNull);
    });

    test('startBrowserHandoff posts to /api/watch/handoff/native/start and returns session', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/watch/handoff/native/start') {
          return http.Response(
            jsonEncode({
              'id': 'hid-123',
              'code': 'ABCD-1234',
              'proof': 'proof-123',
              'verification': '123456',
              'url': 'http://localhost:6767/native-handoff.html?handoffId=hid-123',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      final authService = UburoomAuthService(settingsService: settingsService, httpClient: mockClient);

      final session = await authService.startBrowserHandoff('http://localhost:6767');
      expect(session.handoffId, 'hid-123');
      expect(session.code, 'ABCD-1234');
      expect(session.proof, 'proof-123');
      expect(session.verification, '123456');
      expect(session.displayCode, '123 456');
      expect(session.verificationUrl, 'http://localhost:6767/native-handoff.html?handoffId=hid-123');
    });

    test('pollHandoff returns token when approved and persists credentials', () async {
      var pollCount = 0;
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/watch/handoff/native/poll') {
          pollCount++;
          if (pollCount == 1) {
            return http.Response(jsonEncode({'pending': true}), 202, headers: {'content-type': 'application/json'});
          }
          return http.Response(
            jsonEncode({
              'token': 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
              'expiresAt': 1234567890,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      final authService = UburoomAuthService(settingsService: settingsService, httpClient: mockClient);

      const session = NativeHandoffSession(
        serverUrl: 'http://localhost:6767',
        handoffId: 'hid-123',
        code: 'ABCD-1234',
        proof: 'proof-123',
        verificationUrl: 'http://localhost:6767/native-handoff.html?handoffId=hid-123',
      );

      final token = await authService.pollHandoff(session, interval: const Duration(milliseconds: 1));

      expect(token, 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789');
      expect(authService.serverUrl, 'http://localhost:6767');
      expect(await authService.getToken(), 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789');
    });

    test('pollHandoff aborts early and returns null when isCancelled is true before delay', () async {
      var requestSent = false;
      final mockClient = MockClient((request) async {
        requestSent = true;
        return http.Response('OK', 200);
      });

      final authService = UburoomAuthService(settingsService: settingsService, httpClient: mockClient);
      const session = NativeHandoffSession(
        serverUrl: 'http://localhost:6767',
        handoffId: 'hid-123',
        code: 'ABCD-1234',
        proof: 'proof-123',
        verificationUrl: 'http://localhost:6767/native-handoff.html?handoffId=hid-123',
      );

      final token = await authService.pollHandoff(
        session,
        interval: const Duration(milliseconds: 1),
        isCancelled: () => true,
      );

      expect(token, isNull);
      expect(requestSent, isFalse);
    });

    test('pollHandoff aborts early and returns null when isCancelled becomes true during polling', () async {
      var pollCount = 0;
      var cancelled = false;
      final mockClient = MockClient((request) async {
        pollCount++;
        cancelled = true;
        return http.Response(jsonEncode({'pending': true}), 202, headers: {'content-type': 'application/json'});
      });

      final authService = UburoomAuthService(settingsService: settingsService, httpClient: mockClient);
      const session = NativeHandoffSession(
        serverUrl: 'http://localhost:6767',
        handoffId: 'hid-123',
        code: 'ABCD-1234',
        proof: 'proof-123',
        verificationUrl: 'http://localhost:6767/native-handoff.html?handoffId=hid-123',
      );

      final token = await authService.pollHandoff(
        session,
        interval: const Duration(milliseconds: 1),
        isCancelled: () => cancelled,
      );

      expect(token, isNull);
      expect(pollCount, 1);
    });

    test('normalizeServerUrl extracts scheme, host, port and strips path, query, fragment', () {
      expect(UburoomAuthService.normalizeServerUrl('http://192.168.1.50:6767/'), 'http://192.168.1.50:6767');
      expect(
        UburoomAuthService.normalizeServerUrl('https://watch.example.com/rooms/123?foo=bar#frag'),
        'https://watch.example.com',
      );
      expect(UburoomAuthService.normalizeServerUrl('watch.example.com:8080/path'), 'https://watch.example.com:8080');
      expect(UburoomAuthService.normalizeServerUrl('http://[::1]:6767/api/watch'), 'http://[::1]:6767');
      expect(
        UburoomAuthService.normalizeServerUrl('  HTTPS://WATCH.EXAMPLE.COM:8443/  '),
        'https://watch.example.com:8443',
      );
    });

    test('normalizeServerUrl throws FormatException if host is empty or invalid', () {
      expect(() => UburoomAuthService.normalizeServerUrl(''), throwsFormatException);
      expect(() => UburoomAuthService.normalizeServerUrl('   '), throwsFormatException);
      expect(() => UburoomAuthService.normalizeServerUrl('https://'), throwsFormatException);
      expect(() => UburoomAuthService.normalizeServerUrl('http://'), throwsFormatException);
      expect(() => UburoomAuthService.normalizeServerUrl('https:///path'), throwsFormatException);
      expect(() => UburoomAuthService.normalizeServerUrl('ftp://example.com'), throwsFormatException);
    });
  });
}
