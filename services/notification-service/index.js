const express = require("express");


const otel = require("@opentelemetry/api");
// Returns { trace_id, span_id } of the active OneAgent-instrumented span,
// or {} if no span is active (startup, background timers, etc.).
function tc() {
  const s = otel.trace.getActiveSpan();
  if (!s) return {};
  const c = s.spanContext();
  return { trace_id: c.traceId, span_id: c.spanId };
}

const app = express();
const PORT = process.env.PORT || 3004;

app.get("/health", (req, res) => {
  res.json({ service: "notification-service", status: "ok" });
});

app.get("/notify", (req, res) => {
  const start = Date.now();
  const { orderId, event } = req.query;

  // Simulate sending a notification (email/SMS)
  const delay = 10 + Math.random() * 40; // 10-50ms
  setTimeout(() => {
    const duration = Date.now() - start;
    console.log(JSON.stringify({ service: "notification-service", path: "/notify", orderId, event, status: 200, channel: "email", duration, ...tc() }));
    res.json({ orderId, event, notified: true, channel: "email" });
  }, delay);
});

app.listen(PORT, () => console.log(`notification-service listening on :${PORT}`));
