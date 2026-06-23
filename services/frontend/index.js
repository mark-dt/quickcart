const express = require("express");
const http = require("http");
const path = require("path");


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
const PORT = process.env.PORT || 3000;
const ORDER_SERVICE = process.env.ORDER_SERVICE_URL || "http://order-service.workshop.svc.cluster.local:3001";

app.use(express.static(path.join(__dirname, "public")));

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
  res.json({ service: "frontend", status: "ok" });
});

const dns = require("dns");
const PAYMENT_HEADLESS = process.env.PAYMENT_HEADLESS_HOST || "payment-service-headless.workshop.svc.cluster.local";
const PAYMENT_PORT = 3002;

app.use(express.json());

function postToPod(ip, path, body) {
  return new Promise((resolve, reject) => {
    const options = {
      hostname: ip,
      port: PAYMENT_PORT,
      path,
      method: "POST",
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
    };
    const req = http.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve({ ip, status: res.statusCode, data }));
    });
    req.on("error", (err) => reject({ ip, error: err.message }));
    req.end(body);
  });
}

app.post("/admin/failure-rate", (req, res) => {
  const body = JSON.stringify(req.body);
  dns.resolve4(PAYMENT_HEADLESS, async (err, addresses) => {
    if (err || !addresses || addresses.length === 0) {
      return res.status(502).json({ error: "cannot resolve payment-service pods", details: err?.message });
    }
    const results = await Promise.allSettled(
      addresses.map((ip) => postToPod(ip, "/admin/failure-rate", body))
    );
    const summary = results.map((r) => r.status === "fulfilled" ? r.value : r.reason);
    const failed = results.filter((r) => r.status === "rejected").length;
    res.status(failed === results.length ? 502 : 200).json({ pods: summary });
  });
});

app.get("/order", async (req, res) => {
  const start = Date.now();
  try {
    const result = await fetch(`${ORDER_SERVICE}/order`);
    const duration = Date.now() - start;
    console.log(JSON.stringify({ service: "frontend", method: "GET", path: "/order", status: result.status, duration, ...tc() }));
    res.status(result.status).json(JSON.parse(result.data));
  } catch (err) {
    const duration = Date.now() - start;
    console.error(JSON.stringify({ service: "frontend", method: "GET", path: "/order", status: 502, level: "error", error: err.message, duration, ...tc() }));
    res.status(502).json({ error: "order-service unavailable" });
  }
});

app.listen(PORT, () => console.log(`frontend listening on :${PORT}`));
