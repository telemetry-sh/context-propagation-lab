# Context Propagation Lab

The request succeeded. Its trace ended three services ago.

This interactive Dart lab shows how one healthy checkout becomes disconnected trace
fragments as it crosses asynchronous callbacks, isolates, queues, retries, and fanout.
It compares four propagation strategies under the exact same workload:

1. a mutable process-global value,
2. a Dart `Zone` without boundary carriers,
3. an explicit trace carrier at every hop, and
4. a `Zone` locally plus an explicit envelope at isolate and remote boundaries.

The fourth strategy is the practical default: implicit where Dart guarantees the
asynchronous execution context, explicit where the program serializes work.

## Why this lab exists

Request success and trace integrity are different signals. At the default workload,
all four strategies return the same 92% request success rate. The mutable global
strategy is only 30.2% complete, produces 1,284 wrong-parent spans, and turns each
request into 9.9 roots on average. A Zone-only strategy fixes local callbacks but
still loses context at every isolate, queue, and remote boundary.

The model reports:

- correctly joined, orphan, and wrong-parent spans by boundary,
- complete end-to-end traces,
- failures with enough ancestry to diagnose,
- fragment roots per request,
- carrier writes, encoded bytes, and context operations, and
- a representative event ledger with `trace.id` and `span.parent_id`.

The simulation is deterministic and implemented in [`lib/model.dart`](lib/model.dart).
The native HTTP server is implemented with `dart:io`; the app has no package
dependencies.

## Run it

Requires Dart 3.12 or Docker.

```sh
make run
```

Open <http://127.0.0.1:8080>.

To change the bind address:

```sh
HOST=0.0.0.0 PORT=9000 make run
```

To print the default model as JSON:

```sh
make json | jq
```

With Docker:

```sh
docker build -t context-propagation-lab .
docker run --rm -p 8080:8080 context-propagation-lab
```

The container compiles the Dart server to a native executable and runs it as a
non-root user.

## Verify it

```sh
make check
```

This formats and analyzes the Dart source, checks the deterministic model, proves
real Zone and isolate behavior with the Dart runtime, exercises HTTP routes and
security headers, and compiles a native executable.

The runtime proof specifically checks that:

- a plain `Future` does not invent ambient trace context,
- a `Zone` value survives a local asynchronous callback,
- a worker isolate cannot see the caller's Zone value, and
- an explicit envelope survives the isolate boundary.

CI also builds and health-checks the production container.

## API

`GET /api/simulate` accepts:

| Query parameter | Default | Range |
| --- | ---: | ---: |
| `requests` | 1,200 | 100–10,000 |
| `async_hops` | 5 | 0–12 |
| `isolate_hops` | 2 | 0–8 |
| `message_hops` | 3 | 0–12 |
| `fanout` | 3 | 0–12 |
| `background_task_percent` | 20 | 0–100 |
| `retry_percent` | 12 | 0–80 |
| `failure_percent` | 8 | 0–80 |
| `baggage_fields` | 6 | 0–32 |

Example:

```sh
curl 'http://127.0.0.1:8080/api/simulate?requests=5000&isolate_hops=4&fanout=8' | jq
```

## Instrumentation recipe

Collect identity, boundary, integrity, and cost together:

```text
trace.id
span.id
span.parent_id
trace.context.source
runtime.isolate.id
messaging.envelope.traceparent
trace.fragment.root_count
trace.completeness
trace.wrong_parent_count
baggage.size_bytes
trace.carrier.write_count
trace.context.operation_count
```

This is where [telemetry.sh](https://telemetry.sh) earns its keep: query the
request outcome and its trace topology together, then group the integrity loss by
the boundary and context source that produced it.

## Model boundaries

This is an educational model, not a benchmark of one tracing SDK. It isolates
propagation semantics so the failure is easy to see:

- Dart Zones carry zone-local values through asynchronous callbacks registered in
  that Zone.
- Isolates do not share mutable state and communicate by messages.
- Queues and remote services receive only the context the message or request
  explicitly carries.
- A mutable global can be overwritten by concurrent and background work, creating
  both missing and—more dangerously—plausible but incorrect parentage.

Read the Dart documentation on
[Zones](https://dart.dev/libraries/async/zones) and
[isolates](https://dart.dev/language/isolates) for the runtime guarantees behind
the experiment.

## License

MIT
