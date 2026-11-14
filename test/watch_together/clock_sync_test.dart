import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/watch_together/services/clock_sync.dart';
import 'package:plezy/watch_together/services/drift_correction.dart';

void main() {
  // Expected outputs captured from uburoom shared/sync/timing.mjs, 2026-11-13.
  final traces = jsonDecode(File('test/watch_together/fixtures/timing-v2.json').readAsStringSync()) as Map;
  for (final scenario in traces['scenarios'] as List) {
    test('web clock parity: ${scenario['name']}', () {
      var mono = 0, wall = 1700000000000;
      final clock = ClockSync(nowMs: () => wall, monotonicNowMs: () => mono);
      for (final step in scenario['steps'] as List) {
        mono += step[0] as int;
        wall += step[0] as int;
        final request = clock.begin();
        mono += step[1] as int;
        wall += step[1] as int;
        expect(
          clock.add(request, {
            'serverReceivedAt': step[2],
            'serverSentAt': step[3],
            'serverProcessingMs': step[4],
            'clockEpoch': step[5],
          }),
          step[6],
        );
        final actual = clock.read();
        expect(actual.valid, step[7]);
        expect(clock.revision, step[11]);
        expect(clock.reason, step[12]);
        if (actual.valid) {
          expect(clock.serverNow, closeTo(step[8] as num, 1));
          expect(actual.uncertainty, closeTo(step[9] as num, 0.001));
          expect(actual.stability, closeTo(step[10] as num, 0.001));
        }
      }
    });
  }
  test('reset fences outstanding clock exchanges; wall steps invalidate mapping', () {
    var mono = 0, wall = 1700000000000;
    final c = ClockSync(nowMs: () => wall, monotonicNowMs: () => mono);
    final request = c.begin();
    final timing = {'serverReceivedAt': wall, 'serverSentAt': wall, 'serverProcessingMs': 0, 'clockEpoch': 'a'};
    expect(c.add(request, timing), true);
    mono += 100;
    wall += 5100;
    expect(c.isSynchronized, false);
    expect(c.add(request, timing), false);
  });
  for (final scenario in traces['corrections'] as List) {
    test('web converge/rest parity: ${scenario['name']}', () {
      final c = DriftCorrection();
      for (final step in scenario['steps'] as List) {
        final input = step as List;
        expect(
          c.update(
            now: input[0] as int,
            error: (input[1] as num).toDouble(),
            eligible: input[2] as bool,
            context: input[3] as String,
            uncertaintyMs: (input[4] as num).toDouble(),
            stabilityMs: (input[5] as num).toDouble(),
            frameSeconds: (input[6] as num).toDouble(),
          ),
          closeTo(step[7] as num, 0.000001),
        );
      }
    });
  }
}
