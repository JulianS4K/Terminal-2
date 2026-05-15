// D0 Terminal — Orders page (skeleton).
// Global orders view needs SECDEF RPCs that don't exist yet — admin-only RLS
// on evo_orders / evo_order_items is intentional (customer PII). This page
// stays as a skeleton showing the planned layout until the RPCs land.

(function () {
  'use strict';
  const T = window.Terminal;
  if (T && T.setStatus) T.setStatus('Skeleton — RPC suite pending', 'warn');
})();
