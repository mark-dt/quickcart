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
const PORT = process.env.PORT || 3003;

const WAREHOUSES = {
  "EU-WEST-1": { total: 500, reserved: 120 },
  "US-EAST-1": { total: 200, reserved: 180 },
  "AP-SOUTH-1": { total: 0, reserved: 0 },
};
const WAREHOUSE_IDS = Object.keys(WAREHOUSES);

app.get("/health", (req, res) => {
  res.json({ service: "inventory-service", status: "ok" });
});

app.get("/check", (req, res) => {
  const start = Date.now();
  const { item, qty } = req.query;

  const delay = 20 + Math.random() * 80;
  setTimeout(() => {
    let whId;
    try {
      whId = WAREHOUSE_IDS[Math.floor(Math.random() * WAREHOUSE_IDS.length)];
      const wh = WAREHOUSES[whId];
      const available = wh.total - wh.reserved;
      const restockUnits = available > 0 ? Math.ceil(100 / available) : 0;
      const restockSchedule = new Array(restockUnits).fill("pending");

      const inStock = available > 0;
      const duration = Date.now() - start;
      console.log(JSON.stringify({ service: "inventory-service", path: "/check", item, qty, warehouse: whId, status: 200, available, inStock, duration, ...tc() }));
      res.json({ item, qty: parseInt(qty) || 1, inStock, warehouse: whId, restockDays: restockSchedule.length });
    } catch (err) {
      const duration = Date.now() - start;
      console.error(JSON.stringify({ service: "inventory-service", path: "/check", item, qty, warehouse: whId, status: 500, level: "error", error: err.message, stack: err.stack, duration, ...tc() }));
      res.status(500).json({ item, status: "error", error: err.message });
    }
  }, delay);
});

app.listen(PORT, () => console.log(`inventory-service listening on :${PORT}`));
