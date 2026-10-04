# Loyalty points: cache the tier table instead of calling the CRM per payment

The per-payment call to the CRM tier service was too slow and flaky (the
quality gate blocked it). Tier multipliers are now cached in memory and
refreshed every 5 minutes — no remote call on the payment path any more.

- `payment-service`: in-memory tier table with periodic refresh
