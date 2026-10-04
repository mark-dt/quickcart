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
const PORT = process.env.PORT || 3002;
// Release metadata (set by the deploy overlay; also what OneAgent reports)
const RELEASE = { version: process.env.DT_RELEASE_VERSION || "dev", stage: process.env.DT_RELEASE_STAGE || "local" };
const NOTIFICATION_SERVICE = process.env.NOTIFICATION_SERVICE_URL || "http://notification-service.workshop.svc.cluster.local:3004";
let failureRate = parseFloat(process.env.FAILURE_RATE || "0");

function fetch(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve({ status: res.statusCode, data }));
    }).on("error", reject);
  });
}

function simulateLatency() {
  const base = 50 + Math.random() * 150; // 50-200ms normal
  return new Promise((resolve) => setTimeout(resolve, base));
}

function simulateFailureLatency() {
  const delay = 2000 + Math.random() * 6000; // 2-8s on failure
  return new Promise((resolve) => setTimeout(resolve, delay));
}

// Loyalty points: 1 point per full amount unit, double points from 50 up.
function loyaltyPointsFor(amount) {
  const value = Math.floor(parseFloat(amount) || 0);
  return value >= 50 ? value * 2 : value;
}

// Customer tier (bronze / silver / gold) from the CRM tier service.
// Gold customers earn double points, silver one and a half.
const TIER_MULTIPLIER = { bronze: 1, silver: 1.5, gold: 2 };

async function lookupTier(orderId) {
  // Remote call to the CRM tier service
  await new Promise((resolve) => setTimeout(resolve, 400 + Math.random() * 800));
  if (Math.random() < 0.1) throw new Error("tier service timeout");
  return ["bronze", "silver", "gold"][Math.floor(Math.random() * 3)];
}

app.use(express.json());

app.get("/health", (req, res) => {
  res.json({ service: "payment-service", status: "ok", ...RELEASE, failureRate });
});

app.post("/admin/failure-rate", (req, res) => {
  const { rate } = req.body;
  if (typeof rate !== "number" || rate < 0 || rate > 1) {
    return res.status(400).json({ error: "rate must be a number between 0.0 and 1.0" });
  }
  failureRate = rate;
  console.log(JSON.stringify({ service: "payment-service", event: "failure-rate-changed", failureRate, ...tc() }));
  res.json({ failureRate });
});

app.get("/pay", async (req, res) => {
  const start = Date.now();
  const { orderId, amount } = req.query;

  // Simulate failure based on failureRate
  if (Math.random() < failureRate) {
    await simulateFailureLatency();
    const duration = Date.now() - start;
    console.log(JSON.stringify({ service: "payment-service", path: "/pay", orderId, status: 500, error: "payment processing failed", duration, ...tc() }));
    return res.status(500).json({ error: "payment processing failed", orderId });
  }

  await simulateLatency();

  // Notify on successful payment
  try {
    await fetch(`${NOTIFICATION_SERVICE}/notify?orderId=${orderId}&event=payment_confirmed`);
  } catch (err) {
    console.log(JSON.stringify({ service: "payment-service", path: "/pay", notification_error: err.message, ...tc() }));
  }

  let tier;
  try {
    tier = await lookupTier(orderId);
  } catch (err) {
    const duration = Date.now() - start;
    console.error(JSON.stringify({ service: "payment-service", path: "/pay", orderId, status: 500, level: "error", error: err.message, duration, ...tc() }));
    return res.status(500).json({ error: "loyalty tier lookup failed", orderId });
  }
  const loyaltyPoints = Math.round(loyaltyPointsFor(amount) * TIER_MULTIPLIER[tier]);

  const duration = Date.now() - start;
  console.log(JSON.stringify({ service: "payment-service", path: "/pay", orderId, amount, tier, loyaltyPoints, status: 200, duration, ...tc() }));
  res.json({ orderId, amount, paymentStatus: "confirmed", tier, loyaltyPoints, transactionId: `TXN-${Date.now()}` });
});

app.listen(PORT, () => console.log(`payment-service listening on :${PORT} (failureRate=${failureRate})`));
