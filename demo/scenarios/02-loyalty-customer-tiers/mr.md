# Loyalty points: customer tier multipliers

Loyalty points now depend on the customer's tier from the CRM tier service:
gold customers earn double points, silver one and a half.

- `payment-service`: `lookupTier()` per payment, `tier` in the `/pay` response
