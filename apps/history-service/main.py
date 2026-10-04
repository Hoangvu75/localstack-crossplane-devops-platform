"""history-service — the far side of the message-queue hop.

The three metric services publish "here is what I just measured" whenever they are asked.
This one consumes that topic, keeps the last N snapshots in memory and serves GET
/api/history. Nothing waits for it: if this service dies the other three keep answering.

History is IN MEMORY and lost on restart. That is the right trade for a learning repo;
production would persist it and run several replicas in one consumer group.

No OpenTelemetry code except record_queue_transit() below — see its docstring.
"""

import asyncio
import json
import traceback
import os
import signal
import time
from collections import deque
from datetime import datetime, timezone
from typing import Any, Optional

from aiohttp import web
from aiokafka import AIOKafkaConsumer

# The only OpenTelemetry import in the app services. It solves one problem
# auto-instrumentation cannot — see record_queue_transit().
#
# Guarded import: the SDK is injected into PYTHONPATH by the Operator at runtime and is NOT
# in requirements.txt. Running this image outside the cluster must still work, minus the
# extra span. Telemetry is never allowed to kill the application.
#
#
try:
    from opentelemetry import propagate, trace
    from opentelemetry.trace import SpanKind

    _tracer = trace.get_tracer("history-service.queue-transit")
except ImportError:  # pragma: no cover
    _tracer = None

PORT = int(os.getenv("PORT", "4004"))
KAFKA_BROKERS = os.getenv("KAFKA_BROKERS", "redpanda.redpanda.svc.cluster.local:9092")
TOPIC = os.getenv("METRICS_TOPIC", "node-metrics")
# A fixed consumer group: extra replicas split partitions instead of duplicating data.
GROUP_ID = os.getenv("KAFKA_GROUP_ID", "history-service")
MAX_HISTORY = int(os.getenv("MAX_HISTORY", "100"))

# deque with maxlen evicts the oldest entry by itself. No cleanup, no leak.
history: deque[dict[str, Any]] = deque(maxlen=MAX_HISTORY)
consumer_ready = False


# Clock-skew warning is printed once: if skew exists it exists for every message, and
# printing per message would drown the real logs.
_skew_warned = False


def record_queue_transit(msg: Any) -> None:
    """Draws the time a message spent inside Redpanda as a visible span.

    A broker never shows up as a span. Redpanda ships no tracing at all (564 config keys,
    none about tracing), and neither do Kafka, RabbitMQ or NATS. The OpenTelemetry messaging
    convention models the hop as a PRODUCER/CONSUMER pair, so the queue time is the GAP
    between them — correct as data, invisible on a flame graph. This span fills that gap.

    Only the consumer can write it, which is why the three producers need no code:

        producer  knows the start, NOT the end (it never learns who consumed, or when)
        consumer  knows both — the end is "now", the start travels with the message

    Both inputs arrive for free: msg.timestamp is set by the client LIBRARY (part of the
    Kafka protocol since v0.10) and traceparent is injected by the AGENT.

    It is SYNTHETIC. It measures waiting, not what the broker did — 0.2ms of broker work and
    1.5ms in a partition both land in one 1.7ms bar. Looking inside the broker needs
    Redpanda's own Prometheus metrics, scraped by the Collector. See README §9.4.
    """
    global _skew_warned

    if _tracer is None or not msg.timestamp:
        return

    # Kafka headers are (str, bytes) pairs; None appears on tombstone headers.
    headers = {
        k: v.decode("utf-8", "replace")
        for k, v in (msg.headers or ())
        if v is not None
    }
    ctx = propagate.extract(headers)

    # Without traceparent there is no tree to attach to, and an orphan span is worse than none:
    # it shows up as a stray single-span trace.
    if trace.get_current_span(ctx).get_span_context().trace_id == 0:
        return

    # ── The line whose absence broke this service ───────────────────────
    # msg.timestamp is Kafka milliseconds, OpenTelemetry wants nanoseconds. This
    # assignment was missing: start_ns was read three times below and never set, so this
    # function raised NameError on the FIRST message, every time. The caller did not
    # wrap it, so the consume loop died, its finally cleared consumer_ready, and the task
    # nobody awaited swallowed the traceback. Net effect: a pod that stayed Running with
    # zero restarts, answered /health 200, answered /ready 503 forever, and consumed
    # nothing -- consumer group Empty, /api/history count 0, two lines of log.
    start_ns = msg.timestamp * 1_000_000
    now_ns = time.time_ns()

    # ── Clock skew ───────────────────────────────────────────────────────
    # Start comes from the producer clock, end from the consumer clock — different pods, possibly
    # different nodes. Enough skew produces a NEGATIVE duration.
    #
    # Not hypothetical: measured on this cluster, 5 of 39 producer/consumer pairs came out
    # negative (different cause — kafkajs includes the broker ack — but identical symptom).
    #
    # Skip rather than clamp to 0: a 0ms span reads as "instant queue", which is a lie. No span
    # at least makes someone ask why.
    if start_ns > now_ns:
        if not _skew_warned:
            _skew_warned = True
            print(
                "[history-service] producer clock is ahead of consumer by "
                f"{(start_ns - now_ns) / 1e6:.1f}ms — skipping transit span. "
                "Check NTP on the nodes.",
                flush=True,
            )
        return

    span = _tracer.start_span(
        f"redpanda transit {msg.topic}",
        context=ctx,
        # INTERNAL, not CONSUMER: the real CONSUMER span already exists, and a second one would
        # corrupt the Messaging Queues page in SigNoz.
        kind=SpanKind.INTERNAL,
        start_time=start_ns,
        attributes={
            "messaging.system": "kafka",
            "messaging.destination.name": msg.topic,
            "messaging.kafka.destination.partition": msg.partition,
            "messaging.kafka.message.offset": msg.offset,
            # Marked synthetic on the span itself, so nobody reads it as Redpanda self-reporting.
            "transit.synthetic": True,
            "transit.measured_by": "history-service",
            "server.address": KAFKA_BROKERS,
        },
    )
    span.end(end_time=now_ns)


async def consume() -> None:
    """Consume loop. Runs in the background for the lifetime of the process."""
    global consumer_ready

    # ── Why this is a retry loop, and why every failure is printed ──────────
    # This function used to run once. It connected, set consumer_ready, printed "listening
    # on ...", and then the `async for` raised and the finally set consumer_ready back to
    # False. Because main() starts it with asyncio.create_task() and never awaits the task,
    # the exception was never retrieved and NOTHING was logged.
    #
    # The result was a pod that looks alive and does nothing: /health kept returning 200
    # because the HTTP server was fine, /ready returned 503 forever, Kubernetes marked the
    # pod NotReady and never restarted it because liveness passed. Observed as 578
    # consecutive "Readiness probe failed: HTTP probe failed with statuscode: 503" events
    # against a container with zero restarts and a two-line log.
    attempt = 0
    while True:
        consumer = AIOKafkaConsumer(
            TOPIC,
            bootstrap_servers=KAFKA_BROKERS,
            group_id=GROUP_ID,
            client_id="history-service",
            # latest: start reading from now, not from the beginning of the topic. Old
            # snapshots have no value.
            auto_offset_reset="latest",
            enable_auto_commit=True,
        )
        try:
            await consumer.start()
            consumer_ready = True
            attempt = 0
            print(f"[history-service] listening on {TOPIC} at {KAFKA_BROKERS}", flush=True)

            async for msg in consumer:
                # Called BEFORE parsing: the message crossed the queue whether or not the
                # payload is valid.
                #
                # Wrapped, because this is the line that killed the loop -- it raised
                # NameError on every message from a missing start_ns assignment. That one
                # is fixed at the source now, but the wrapper stays: this call exists only
                # to DESCRIBE the work, and telemetry must never break the path it is
                # measuring. A dropped span is a gap in a graph; an unhandled exception
                # here is a service that silently stops consuming.
                try:
                    record_queue_transit(msg)
                except Exception as err:  # noqa: BLE001
                    print(f"[history-service] span failed, continuing: {err!r}", flush=True)

                try:
                    payload = json.loads(msg.value.decode())
                except Exception as err:  # noqa: BLE001
                    # A bad message must not kill the loop, or it blocks the partition forever.
                    print(f"[history-service] bad payload, skipping: {err}", flush=True)
                    continue

                history.append(
                    {
                        "receivedAt": datetime.now(timezone.utc).isoformat(),
                        "source": (msg.key or b"?").decode(),
                        "partition": msg.partition,
                        "offset": msg.offset,
                        "service": payload.get("service"),
                        "language": payload.get("language"),
                        "summary": payload.get("summary"),
                    }
                )

        except asyncio.CancelledError:
            # Shutdown, not a failure. Let it propagate so the process can exit.
            raise
        except Exception as err:  # noqa: BLE001
            # The whole point of the rewrite: say WHY the loop stopped. Previously this
            # exception went into a task nobody awaited and vanished.
            print(f"[history-service] consume loop died: {err!r}", flush=True)
            traceback.print_exc()
        finally:
            consumer_ready = False
            try:
                await consumer.stop()
            except Exception:  # noqa: BLE001
                pass

        attempt += 1
        delay = min(60, 2 ** min(attempt, 6))
        print(
            f"[history-service] reconnecting to Kafka in {delay}s (attempt {attempt})",
            flush=True,
        )
        await asyncio.sleep(delay)


async def health(_req: web.Request) -> web.Response:
    return web.json_response({"status": "UP", "service": "history-service"})


async def ready(_req: web.Request) -> web.Response:
    # Unlike the other three, this service has nothing to serve until Kafka is connected, so
    # readiness genuinely reflects consumer state.
    if not consumer_ready:
        return web.json_response(
            {"status": "NOT_READY", "reason": "Kafka not connected"}, status=503
        )
    return web.json_response({"status": "READY", "service": "history-service"})


async def get_history(req: web.Request) -> web.Response:
    limit = min(int(req.query.get("limit", MAX_HISTORY)), MAX_HISTORY)
    items = list(history)[-limit:]
    return web.json_response(
        {
            "service": "history-service",
            "language": "python",
            "topic": TOPIC,
            "count": len(items),
            "capacity": MAX_HISTORY,
            "note": "History is in memory and lost on pod restart.",
            "items": list(reversed(items)),
        }
    )


async def main() -> None:
    # Background, NOT awaited: the HTTP server must come up even if the broker is not ready,
    # otherwise /health never answers and Kubernetes kills the pod first.
    task = asyncio.create_task(consume())

    app = web.Application()
    app.router.add_get("/health", health)
    app.router.add_get("/ready", ready)
    app.router.add_get("/api/history", get_history)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", PORT)
    await site.start()
    print(f"[history-service] HTTP :{PORT}", flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()

    print("[history-service] shutting down", flush=True)
    task.cancel()
    await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
