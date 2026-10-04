# Loyalty points for every payment

Customers now earn loyalty points on every confirmed payment: one point per
full amount unit, double points for orders from 50 up. The points are returned
by payment-service and shown in the order feed.

- `payment-service`: `loyaltyPointsFor(amount)`, `loyaltyPoints` in the `/pay` response and log
- `frontend`: `+N pts` tag per order
