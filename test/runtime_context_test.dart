import 'dart:async';
import 'dart:isolate';

Future<void> main() async {
  const traceKey = #traceId;
  final futureTrace = await runZoned(() async {
    await Future<void>.delayed(Duration.zero);
    return Zone.current[traceKey] as String?;
  }, zoneValues: {traceKey: 'trace-zone-731'});
  _expect(
    futureTrace == 'trace-zone-731',
    'zone-local value survives an ordinary Future',
  );

  final isolateTrace = await runZoned(
    () => Isolate.run(() => Zone.current[traceKey] as String?),
    zoneValues: {traceKey: 'trace-zone-731'},
  );
  _expect(
    isolateTrace == null,
    'zone-local value does not appear in a worker isolate',
  );

  final envelope = {'traceparent': '00-trace-envelope-731-span-001-01'};
  final extracted = await Isolate.run(() => envelope['traceparent']);
  _expect(
    extracted == envelope['traceparent'],
    'explicit envelope survives isolate message transfer',
  );

  // ignore: avoid_print
  print(
    'RuntimeContextTest: Future, Zone, isolate, and envelope behavior passed',
  );
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('assertion failed: $message');
}
