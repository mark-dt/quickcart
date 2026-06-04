const express = require("express");

const app = express();
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
    const whId = WAREHOUSE_IDS[Math.floor(Math.random() * WAREHOUSE_IDS.length)];
    const wh = WAREHOUSES[whId];
    const available = wh.total - wh.reserved;
    const restockUnits = Math.ceil(100 / available);
    const restockSchedule = new Array(restockUnits).fill("pending");

    const inStock = available > 0;
    const duration = Date.now() - start;
    console.log(JSON.stringify({ service: "inventory-service", path: "/check", item, qty, warehouse: whId, available, inStock, duration }));
    res.json({ item, qty: parseInt(qty) || 1, inStock, warehouse: whId, restockDays: restockSchedule.length });
  }, delay);
});

app.listen(PORT, () => console.log(`inventory-service listening on :${PORT}`));
