const express = require("express");
const http = require("http");


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
const PORT = process.env.PORT || 3001;
const PAYMENT_SERVICE = process.env.PAYMENT_SERVICE_URL || "http://payment-service.workshop.svc.cluster.local:3002";
const INVENTORY_SERVICE = process.env.INVENTORY_SERVICE_URL || "http://inventory-service.workshop.svc.cluster.local:3003";

const ITEMS = ["WIDGET-1", "WIDGET-2", "WIDGET-3"];
const PRICES = { "WIDGET-1": 49.99, "WIDGET-2": 29.99, "WIDGET-3": 89.99 };
const PRODUCT_META = {
  "WIDGET-1": { category: "electronics", weight: 0.5 },
};

function fetch(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve({ status: res.statusCode, data }));
    }).on("error", reject);
  });
}

app.get("/health", (req, res) => {
  res.json({ service: "order-service", status: "ok" });
});

app.get("/order", async (req, res) => {
  const start = Date.now();
  const orderId = `ORD-${Date.now()}`;
  const item = ITEMS[Math.floor(Math.random() * ITEMS.length)];
  const amount = PRICES[item];

  try {
    const [paymentResult, inventoryResult] = await Promise.all([
      fetch(`${PAYMENT_SERVICE}/pay?orderId=${orderId}&amount=${amount}`),
      fetch(`${INVENTORY_SERVICE}/check?item=${item}&qty=1`),
    ]);

    const duration = Date.now() - start;
    const paymentOk = paymentResult.status === 200;
    const inventoryOk = inventoryResult.status === 200;

    const meta = PRODUCT_META[item];
    const category = meta ? meta.category : "general";

    const status = paymentOk && inventoryOk ? 200 : 500;
    console.log(JSON.stringify({ service: "order-service", path: "/order", orderId, item, category, status, paymentStatus: paymentResult.status, inventoryStatus: inventoryResult.status, duration, ...tc() }));

    if (paymentOk && inventoryOk) {
      res.json({ orderId, item, category, status: "confirmed", payment: JSON.parse(paymentResult.data), inventory: JSON.parse(inventoryResult.data) });
    } else {
      res.status(500).json({ orderId, item, status: "failed", paymentOk, inventoryOk });
    }
  } catch (err) {
    const duration = Date.now() - start;
    console.error(JSON.stringify({ service: "order-service", path: "/order", orderId, item, status: 502, level: "error", error: err.message, stack: err.stack, duration, ...tc() }));
    res.status(502).json({ orderId, status: "error", error: err.message });
  }
});

app.listen(PORT, () => console.log(`order-service listening on :${PORT}`));
