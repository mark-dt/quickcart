const express = require("express");

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
    console.log(JSON.stringify({ service: "notification-service", path: "/notify", orderId, event, status: 200, channel: "email", duration }));
    res.json({ orderId, event, notified: true, channel: "email" });
  }, delay);
});

app.listen(PORT, () => console.log(`notification-service listening on :${PORT}`));
