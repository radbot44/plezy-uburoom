import 'package:flutter_test/flutter_test.dart';
import 'package:openwatchparty/openwatchparty.dart' as owp;
import 'package:plezy/watch_together/services/watch_party_relays.dart';

void main() {
  group('canonicalRelayBaseUrl', () {
    test('lower-cases scheme and host, keeps port and path case, drops trailing slashes', () {
      expect(canonicalRelayBaseUrl('  HTTPS://Relay.Example.Test/path///  '), 'https://relay.example.test/path');
      expect(canonicalRelayBaseUrl('HTTP://Relay.Example.Test:8080/Prefix/'), 'http://relay.example.test:8080/Prefix');
      expect(canonicalRelayBaseUrl('http://127.0.0.1:19030'), 'http://127.0.0.1:19030');
    });

    test('drops a default port', () {
      expect(canonicalRelayBaseUrl('https://relay.example.test:443'), 'https://relay.example.test');
      expect(canonicalRelayBaseUrl('http://relay.example.test:80/'), 'http://relay.example.test');
    });

    test('keeps the brackets of an IPv6 literal, so the WebSocket URL still names the host', () {
      expect(canonicalRelayBaseUrl('http://[::1]:8080'), 'http://[::1]:8080');
      expect(relaysFor(canonicalRelayBaseUrl('http://[::1]:8080')).list.single.url, 'ws://[::1]:8080/v1/ws');
    });

    test('refuses what the SDK cannot use', () {
      for (final input in [
        '',
        '   ',
        'relay.example.test',
        'ws://relay.example.test',
        'wss://relay.example.test',
        'ftp://relay.example.test',
        'https://',
        'https:///path',
        'https://relay.example.test/path?wrong=route',
        'https://relay.example.test/#fragment',
        'https://user:secret@relay.example.test',
        'http://[not a host',
      ]) {
        expect(canonicalRelayBaseUrl(input), isNull, reason: input);
      }
    });

    test('a canonical base is its own canonical form', () {
      for (final input in ['https://relay.example.test/path', 'http://relay.example.test:8080', 'https://h/a%20b']) {
        final base = canonicalRelayBaseUrl(input)!;
        expect(canonicalRelayBaseUrl(base), base, reason: input);
      }
    });
  });

  group('relaysFor', () {
    test('null is the public relays', () {
      final relays = relaysFor(null);
      expect(relays.list, isNotEmpty);
      expect(relays.list.every((relay) => relay.url.startsWith('wss://')), isTrue);
    });

    test('a custom base is the only relay, on its WebSocket path', () {
      expect(relaysFor('http://127.0.0.1:19030').list.single.url, 'ws://127.0.0.1:19030/v1/ws');
      expect(relaysFor('https://relay.example.test/prefix').list.single.url, 'wss://relay.example.test/prefix/v1/ws');
    });

    test('a custom relay owns every code', () {
      final relays = relaysFor('https://relay.example.test');
      for (final code in ['222222', 'ZZZZZZ', 'K7MQ2X']) {
        expect(relays.relayFor(code), same(relays.list.single), reason: code);
      }
    });
  });

  group('relayScopeOf', () {
    test('public relays share one scope; each custom base has its own, stable one', () {
      expect(relayScopeOf(null), 'public');
      final a = relayScopeOf('https://relay-a.example.test');
      final b = relayScopeOf('https://relay-b.example.test');
      expect(a, isNot(b));
      expect(a, isNot('public'));
      expect(relayScopeOf('https://relay-a.example.test'), a);
      expect(a, matches(RegExp(r'^[0-9a-f]{64}$')), reason: 'the scope must not hold the URL itself');
    });
  });

  group('normalizeRoomCode', () {
    test('accepts a code as typed or pasted', () {
      expect(normalizeRoomCode('K7M-Q2X'), 'K7MQ2X');
      expect(normalizeRoomCode('k7mq2x'), 'K7MQ2X');
      expect(normalizeRoomCode(' k7m q2x\n'), 'K7MQ2X');
      expect(normalizeRoomCode('K7M\u2013Q2X'), 'K7MQ2X');
    });

    test('refuses what is not 6 symbols of the code alphabet', () {
      for (final input in ['', 'K7MQ2', 'K7MQ2XX', 'ROOM12', 'K7M-Q2I', 'K7M_Q2X', 'K7MQ2X!', 'ÄBCDEF', 'ABCDE']) {
        expect(normalizeRoomCode(input), isNull, reason: input);
      }
    });

    test('agrees with the SDK formatting', () {
      expect(owp.formatCode(normalizeRoomCode('k7m q2x')!), 'K7M-Q2X');
    });

    test('extracts uburoom uuid from invite urls and fragments', () {
      const expectedUuid = '12345678-1234-1234-1234-123456789abc';

      expect(normalizeRoomCode('https://watch.example.com/rooms/12345678-1234-1234-1234-123456789abc'), expectedUuid);
      expect(normalizeRoomCode('https://watch.example.com/watch/12345678-1234-1234-1234-123456789abc'), expectedUuid);
      expect(normalizeRoomCode('https://watch.example.com/r/12345678-1234-1234-1234-123456789abc'), expectedUuid);
      expect(normalizeRoomCode('https://watch.example.com/?roomId=12345678-1234-1234-1234-123456789abc'), expectedUuid);
      expect(normalizeRoomCode('https://watch.example.com/?room=12345678-1234-1234-1234-123456789abc'), expectedUuid);
      expect(normalizeRoomCode('https://watch.example.com/#room=12345678-1234-1234-1234-123456789abc'), expectedUuid);
      expect(normalizeRoomCode('https://watch.example.com/#12345678-1234-1234-1234-123456789abc'), expectedUuid);
      expect(normalizeRoomCode('https://watch.example.com/#/rooms/12345678-1234-1234-1234-123456789abc'), expectedUuid);
      expect(normalizeRoomCode('?roomId=12345678-1234-1234-1234-123456789abc'), expectedUuid);
      expect(normalizeRoomCode('?room=12345678-1234-1234-1234-123456789abc'), expectedUuid);
      expect(normalizeRoomCode('#room=12345678-1234-1234-1234-123456789abc'), expectedUuid);
      expect(normalizeRoomCode('#12345678-1234-1234-1234-123456789abc'), expectedUuid);
    });

    test('lowercases uppercase uuids in urls and raw inputs', () {
      const upper = 'ABCDEF12-3456-7890-ABCD-EF1234567890';
      const lower = 'abcdef12-3456-7890-abcd-ef1234567890';
      expect(normalizeRoomCode('https://watch.example.com/rooms/$upper'), lower);
      expect(normalizeRoomCode('https://watch.example.com/#room=$upper'), lower);
      expect(normalizeRoomCode(upper), lower);
    });

    test('handles 8-hex room codes across urls and fragments', () {
      expect(normalizeRoomCode('https://watch.example.com/rooms/1a2b3c4d'), '1a2b3c4d');
      expect(normalizeRoomCode('https://watch.example.com/#room=1a2b3c4d'), '1a2b3c4d');
      expect(normalizeRoomCode('https://watch.example.com/#1a2b3c4d'), '1a2b3c4d');
      expect(normalizeRoomCode('#room=1a2b3c4d'), '1a2b3c4d');
      expect(normalizeRoomCode('1A2B3C4D'), '1a2b3c4d');
    });

    test('refuses urls with no room code candidate', () {
      expect(normalizeRoomCode('https://watch.example.com/'), isNull);
      expect(normalizeRoomCode('https://watch.example.com/about'), isNull);
    });
  });

  test('room bounds are the SDK limits', () {
    expect(maxRoomOffsetMs, 7 * 24 * 60 * 60 * 1000);
    expect((minRoomRate, maxRoomRate), (0.5, 2.0));
  });
}
