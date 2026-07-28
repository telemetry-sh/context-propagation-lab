import '../lib/model.dart';

void main() {
  final simulation = simulate(const Config());
  final strategies = simulation['strategies']! as List<Map<String, Object>>;
  _expect(strategies.length == 4, 'four strategies');

  final ambient = strategies[0]['metrics']! as Map<String, Object>;
  final zone = strategies[1]['metrics']! as Map<String, Object>;
  final explicit = strategies[2]['metrics']! as Map<String, Object>;
  final hybrid = strategies[3]['metrics']! as Map<String, Object>;

  _expect(
    (ambient['traceCompletenessPercent']! as double) < 40,
    'mutable global loses most graph edges',
  );
  _expect(
    (ambient['wrongParentSpans']! as int) > 0,
    'mutable global contaminates parentage',
  );
  _expect(
    (zone['traceCompletenessPercent']! as double) >
        (ambient['traceCompletenessPercent']! as double),
    'zones preserve local async context',
  );
  _expect(
    (zone['orphanSpans']! as int) > 0,
    'zones do not cross isolate and message boundaries',
  );
  _expect(
    explicit['traceCompletenessPercent'] == 100.0,
    'explicit propagation completes traces',
  );
  _expect(
    hybrid['traceCompletenessPercent'] == 100.0,
    'hybrid propagation completes traces',
  );
  _expect(
    (hybrid['carrierBytes']! as int) < (explicit['carrierBytes']! as int),
    'hybrid uses fewer carrier bytes',
  );
  _expect(
    hybrid['completeTracesPercent'] == 100.0,
    'hybrid has complete request graphs',
  );

  final clamped = Config(
    requests: -1,
    asyncHops: 99,
    isolateHops: -1,
    messageHops: 99,
    fanout: -1,
    backgroundTaskPercent: 999,
    retryPercent: -1,
    failurePercent: 999,
    baggageFields: 999,
  ).normalize();
  _expect(clamped.requests == 100, 'requests clamp');
  _expect(clamped.asyncHops == 12, 'async clamp');
  _expect(clamped.isolateHops == 0, 'isolate clamp');
  _expect(clamped.messageHops == 12, 'message clamp');
  _expect(clamped.fanout == 0, 'fanout clamp');
  _expect(clamped.backgroundTaskPercent == 100, 'background clamp');
  _expect(clamped.retryPercent == 0, 'retry clamp');
  _expect(clamped.failurePercent == 80, 'failure clamp');
  _expect(clamped.baggageFields == 32, 'baggage clamp');

  stdoutSuccess();
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError('assertion failed: $message');
  }
}

void stdoutSuccess() {
  // Kept separate so the analyzer verifies the test reaches the final line.
  // ignore: avoid_print
  print(
    'ModelTest: context loss, hybrid completeness, overhead, and clamps passed',
  );
}
