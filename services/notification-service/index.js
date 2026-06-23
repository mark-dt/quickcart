const express = require("express");


const { AsyncLocalStorage } = require("async_hooks");
// Stash the active trace context (parsed from the W3C `traceparent` header
// that OneAgent's HTTP auto-instrumentation puts on every incoming request)
// in async-local storage. tc() reads from there so every console.log inside
// a request handler can be enriched with trace_id/span_id without changing
// function signatures.
const traceStore = new AsyncLocalStorage();
function traceMiddleware(req, _res, next) {
  const tp = req.headers["traceparent"];
  if (tp) {
    const parts = tp.split("-"); // 00-<trace_id>-<span_id>-<flags>
    if (parts.length >= 4) {
      return traceStore.run({ trace_id: parts[1], span_id: parts[2] }, () => next());
    }
  }
  next();
}
function tc() {
  return traceStore.getStore() || {};
}

const app = express();
app.use(traceMiddleware);
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
