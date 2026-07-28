import 'dart:math' as math;

final class Config {
  const Config({
    this.requests = 1200,
    this.asyncHops = 5,
    this.isolateHops = 2,
    this.messageHops = 3,
    this.fanout = 3,
    this.backgroundTaskPercent = 20,
    this.retryPercent = 12,
    this.failurePercent = 8,
    this.baggageFields = 6,
  });

  factory Config.fromQuery(Map<String, String> query) {
    final defaults = const Config();
    return Config(
      requests: _integer(query['requests'], defaults.requests),
      asyncHops: _integer(query['async_hops'], defaults.asyncHops),
      isolateHops: _integer(query['isolate_hops'], defaults.isolateHops),
      messageHops: _integer(query['message_hops'], defaults.messageHops),
      fanout: _integer(query['fanout'], defaults.fanout),
      backgroundTaskPercent: _integer(
        query['background_task_percent'],
        defaults.backgroundTaskPercent,
      ),
      retryPercent: _integer(query['retry_percent'], defaults.retryPercent),
      failurePercent: _integer(
        query['failure_percent'],
        defaults.failurePercent,
      ),
      baggageFields: _integer(query['baggage_fields'], defaults.baggageFields),
    );
  }

  final int requests;
  final int asyncHops;
  final int isolateHops;
  final int messageHops;
  final int fanout;
  final int backgroundTaskPercent;
  final int retryPercent;
  final int failurePercent;
  final int baggageFields;

  Config normalize() => Config(
    requests: requests.clamp(100, 10000),
    asyncHops: asyncHops.clamp(0, 12),
    isolateHops: isolateHops.clamp(0, 8),
    messageHops: messageHops.clamp(0, 12),
    fanout: fanout.clamp(0, 12),
    backgroundTaskPercent: backgroundTaskPercent.clamp(0, 100),
    retryPercent: retryPercent.clamp(0, 80),
    failurePercent: failurePercent.clamp(0, 80),
    baggageFields: baggageFields.clamp(0, 32),
  );

  Map<String, Object> toJson() => {
    'requests': requests,
    'asyncHops': asyncHops,
    'isolateHops': isolateHops,
    'messageHops': messageHops,
    'fanout': fanout,
    'backgroundTaskPercent': backgroundTaskPercent,
    'retryPercent': retryPercent,
    'failurePercent': failurePercent,
    'baggageFields': baggageFields,
  };

  static int _integer(String? raw, int fallback) =>
      int.tryParse(raw ?? '') ?? fallback;
}

const _policies = [
  'ambient_global',
  'zone_only',
  'explicit_everywhere',
  'zone_plus_envelope',
];

Map<String, Object> simulate(Config rawConfig) {
  final config = rawConfig.normalize();
  final strategies = _policies
      .map((policy) => _simulatePolicy(config, policy))
      .toList(growable: false);
  return {
    'model': 'deterministic asynchronous trace graph',
    'config': config.toJson(),
    'strategies': strategies,
  };
}

Map<String, Object> _simulatePolicy(Config config, String policy) {
  final retryRequests = (config.requests * config.retryPercent / 100).round();
  final failures = (config.requests * config.failurePercent / 100).round();
  final specs = <_StageSpec>[
    _StageSpec('gateway.accept', 'root', config.requests),
    for (var index = 0; index < config.asyncHops; index++)
      _StageSpec(_asyncName(index), 'async_callback', config.requests),
    for (var index = 0; index < config.isolateHops; index++)
      _StageSpec(_isolateName(index), 'isolate_message', config.requests),
    for (var index = 0; index < config.messageHops; index++)
      _StageSpec(_messageName(index), 'queue_message', config.requests),
    if (config.fanout > 0)
      _StageSpec(
        'catalog.fanout',
        'remote_fanout',
        config.requests * config.fanout,
      ),
    if (retryRequests > 0)
      _StageSpec('payment.retry', 'async_callback', retryRequests * 2),
  ];

  final ambientCorrectRate =
      (0.78 -
              config.requests / 10000 * 0.30 -
              config.fanout * 0.025 -
              config.backgroundTaskPercent * 0.002)
          .clamp(0.30, 0.76);
  final ambientWrongRate = ((1 - ambientCorrectRate) * 0.55).clamp(0.0, 0.42);

  final stages = <Map<String, Object>>[];
  var expectedSpans = 0;
  var correctSpans = 0;
  var orphanSpans = 0;
  var wrongParentSpans = 0;
  var completeProbability = 1.0;

  for (var index = 0; index < specs.length; index++) {
    final spec = specs[index];
    final rates = _ratesFor(
      policy,
      spec.boundary,
      ambientCorrectRate,
      ambientWrongRate,
    );
    final correct = (spec.expected * rates.correct).round().clamp(
      0,
      spec.expected,
    );
    final wrong = (spec.expected * rates.wrong).round().clamp(
      0,
      spec.expected - correct,
    );
    final orphan = spec.expected - correct - wrong;
    final completeness = spec.expected == 0
        ? 100.0
        : correct / spec.expected * 100;

    expectedSpans += spec.expected;
    correctSpans += correct;
    orphanSpans += orphan;
    wrongParentSpans += wrong;

    if (spec.boundary != 'root') {
      final units = spec.expected / config.requests;
      completeProbability *= math.pow(rates.correct, units).toDouble();
    }

    stages.add({
      'index': index,
      'stage': spec.name,
      'boundary': spec.boundary,
      'expectedSpans': spec.expected,
      'correctSpans': correct,
      'orphanSpans': orphan,
      'wrongParentSpans': wrong,
      'completenessPercent': _round1(completeness),
    });
  }

  final metadata = _metadata(policy);
  final completeness = correctSpans / math.max(1, expectedSpans) * 100;
  final completeTraces = completeProbability * 100;
  final wrongRatio = wrongParentSpans / math.max(1, expectedSpans);
  final diagnosableFailures = (completeness * 1.45 * (1 - wrongRatio)).clamp(
    0.0,
    100.0,
  );
  final carrierSize = 55 + config.baggageFields * 24;
  final nonRootSpans = expectedSpans - config.requests;
  final remoteSpans = specs
      .where(
        (spec) =>
            spec.boundary == 'isolate_message' ||
            spec.boundary == 'queue_message' ||
            spec.boundary == 'remote_fanout',
      )
      .fold<int>(0, (total, spec) => total + spec.expected);
  final carrierWrites = switch (policy) {
    'explicit_everywhere' => nonRootSpans,
    'zone_plus_envelope' => remoteSpans,
    _ => 0,
  };
  final zoneBindings = switch (policy) {
    'zone_only' || 'zone_plus_envelope' => config.requests,
    _ => 0,
  };
  final contextOperations = carrierWrites * 2 + zoneBindings;
  final carrierBytes = carrierWrites * carrierSize;
  final fragments = config.requests + orphanSpans;

  return {
    ...metadata,
    'metrics': {
      'requests': config.requests,
      'successfulRequests': config.requests - failures,
      'failedRequests': failures,
      'expectedSpans': expectedSpans,
      'correctSpans': correctSpans,
      'orphanSpans': orphanSpans,
      'wrongParentSpans': wrongParentSpans,
      'traceCompletenessPercent': _round1(completeness),
      'completeTracesPercent': _round1(completeTraces),
      'diagnosableFailuresPercent': _round1(diagnosableFailures),
      'fragmentRoots': fragments,
      'fragmentMultiplier': _round1(fragments / config.requests),
      'wrongParentPercent': _round1(wrongRatio * 100),
      'carrierBytes': carrierBytes,
      'carrierMegabytes': _round2(carrierBytes / 1000000),
      'contextOperations': contextOperations,
      'zoneBindings': zoneBindings,
      'carrierWrites': carrierWrites,
    },
    'stages': stages,
    'events': _sampleEvents(
      config,
      policy,
      ambientCorrectRate,
      ambientWrongRate,
    ),
  };
}

_Rates _ratesFor(
  String policy,
  String boundary,
  double ambientCorrect,
  double ambientWrong,
) {
  if (boundary == 'root') return const _Rates(1, 0);
  return switch (policy) {
    'ambient_global' when boundary == 'async_callback' => _Rates(
      ambientCorrect,
      ambientWrong,
    ),
    'ambient_global' => const _Rates(0, 0),
    'zone_only' when boundary == 'async_callback' => const _Rates(1, 0),
    'zone_only' => const _Rates(0, 0),
    'explicit_everywhere' || 'zone_plus_envelope' => const _Rates(1, 0),
    _ => const _Rates(0, 0),
  };
}

List<Map<String, Object>> _sampleEvents(
  Config config,
  String policy,
  double ambientCorrect,
  double ambientWrong,
) {
  final specs = <_EventSpec>[
    const _EventSpec('gateway', 'root'),
    for (var index = 0; index < math.min(3, config.asyncHops); index++)
      _EventSpec(_asyncName(index), 'async_callback'),
    for (var index = 0; index < math.min(2, config.isolateHops); index++)
      _EventSpec(_isolateName(index), 'isolate_message'),
    for (var index = 0; index < math.min(2, config.messageHops); index++)
      _EventSpec(_messageName(index), 'queue_message'),
    if (config.fanout > 0)
      const _EventSpec('catalog.shard-02', 'remote_fanout'),
    if (config.retryPercent > 0)
      const _EventSpec('payment.retry', 'async_callback'),
  ];

  final events = <Map<String, Object>>[];
  var parentSpanId = 'none';
  for (var index = 0; index < specs.length; index++) {
    final spec = specs[index];
    final state = _sampleContextState(
      policy,
      spec.boundary,
      index,
      ambientCorrect,
      ambientWrong,
    );
    final spanId = 'sp-${(index + 1).toString().padLeft(3, '0')}';
    final traceId = switch (state) {
      'wrong' => 'trace-other-084',
      'missing' => 'trace-fragment-${(index + 1).toString().padLeft(2, '0')}',
      _ => 'trace-checkout-731',
    };
    final eventParent = switch (state) {
      'missing' => 'none',
      'wrong' => 'sp-other-041',
      _ => parentSpanId,
    };
    final source = switch ((policy, spec.boundary)) {
      (_, 'root') => 'request header',
      ('zone_only' || 'zone_plus_envelope', 'async_callback') => 'Zone value',
      ('explicit_everywhere', _) => 'explicit carrier',
      ('zone_plus_envelope', _) => 'message envelope',
      ('ambient_global', 'async_callback') => 'mutable global',
      _ => 'none',
    };
    events.add({
      'sequence': index + 1,
      'service': spec.service,
      'boundary': spec.boundary,
      'traceId': traceId,
      'spanId': spanId,
      'parentSpanId': eventParent,
      'contextState': state,
      'contextSource': source,
      'durationMs': 4 + (index * 7) % 29,
      'status': index == specs.length - 2 && config.failurePercent > 0
          ? 'error'
          : 'ok',
    });
    if (state == 'joined' || state == 'zone' || state == 'injected') {
      parentSpanId = spanId;
    }
  }
  return events;
}

String _sampleContextState(
  String policy,
  String boundary,
  int index,
  double ambientCorrect,
  double ambientWrong,
) {
  if (boundary == 'root') return 'joined';
  return switch (policy) {
    'explicit_everywhere' => 'injected',
    'zone_plus_envelope' when boundary == 'async_callback' => 'zone',
    'zone_plus_envelope' => 'injected',
    'zone_only' when boundary == 'async_callback' => 'zone',
    'zone_only' => 'missing',
    'ambient_global' when boundary != 'async_callback' => 'missing',
    'ambient_global' when index % 3 == 1 && ambientCorrect > 0.3 => 'joined',
    'ambient_global' when index % 3 == 2 && ambientWrong > 0.05 => 'wrong',
    _ => 'missing',
  };
}

Map<String, Object> _metadata(String policy) => switch (policy) {
  'ambient_global' => {
    'policy': policy,
    'name': 'Mutable global',
    'kicker': 'CONTEXT BY ACCIDENT',
    'description':
        'Concurrent callbacks read whichever request most recently overwrote shared state.',
    'tradeoff':
        'No carrier overhead, but cross-request contamination and orphan remote work make traces untrustworthy.',
    'semantics': 'Implicit process-global trace state',
    'color': '#ff5c63',
    'recommended': false,
  },
  'zone_only' => {
    'policy': policy,
    'name': 'Zone only',
    'kicker': 'ASYNC EXTENT',
    'description':
        'Zone-local context follows Futures, timers, and Streams scheduled inside the request.',
    'tradeoff':
        'Correct within one isolate; isolate and message boundaries still require an explicit carrier.',
    'semantics': 'Zone value inside one isolate',
    'color': '#35c9a5',
    'recommended': false,
  },
  'explicit_everywhere' => {
    'policy': policy,
    'name': 'Explicit everywhere',
    'kicker': 'CARRIER EVERY HOP',
    'description':
        'Every callback and message receives an injected trace and baggage envelope.',
    'tradeoff':
        'Complete and obvious, with repetitive plumbing and the highest carrier serialization cost.',
    'semantics': 'Inject and extract at every boundary',
    'color': '#ffbd3d',
    'recommended': false,
  },
  _ => {
    'policy': policy,
    'name': 'Zone + envelope',
    'kicker': 'LOCAL IMPLICIT / REMOTE EXPLICIT',
    'description':
        'Zones carry local async state; isolate, queue, and fanout messages carry trace context explicitly.',
    'tradeoff':
        'Requires boundary instrumentation, but preserves complete traces with fewer carrier operations.',
    'semantics': 'Zone locally, W3C-style envelope remotely',
    'color': '#9482ff',
    'recommended': true,
  },
};

String _asyncName(int index) {
  const names = [
    'auth.future',
    'pricing.stream',
    'payment.timer',
    'response.microtask',
    'receipt.callback',
  ];
  return index < names.length ? names[index] : 'async.hop-${index + 1}';
}

String _isolateName(int index) {
  const names = ['risk.isolate', 'tax.isolate', 'fraud.isolate'];
  return index < names.length ? names[index] : 'worker.isolate-${index + 1}';
}

String _messageName(int index) {
  const names = ['inventory.queue', 'ledger.queue', 'email.queue'];
  return index < names.length ? names[index] : 'message.queue-${index + 1}';
}

double _round1(num value) => (value * 10).round() / 10;
double _round2(num value) => (value * 100).round() / 100;

final class _StageSpec {
  const _StageSpec(this.name, this.boundary, this.expected);

  final String name;
  final String boundary;
  final int expected;
}

final class _EventSpec {
  const _EventSpec(this.service, this.boundary);

  final String service;
  final String boundary;
}

final class _Rates {
  const _Rates(this.correct, this.wrong);

  final double correct;
  final double wrong;
}
