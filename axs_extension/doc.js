// Shape checks on what a page received, so a read can stop as soon as the inventory is in. The document itself is
// built on our server (core/axs_ext_doc.py), from the same answers: these only decide when to stop waiting.
"use strict";

function* walkJson(node, depth = 0) {
  if (depth > 6 || node === null || typeof node !== "object") return;
  if (!Array.isArray(node)) yield node;
  for (const v of Array.isArray(node) ? node : Object.values(node)) {
    if (v !== null && typeof v === "object") yield* walkJson(v, depth + 1);
  }
}

// what one answer holds: seat items (offers[].items[]), a price book (offerPrices), on-sale state
function shapeOf(json) {
  const s = { offers: false, prices: false, onsale: false,
              // offer_search answered: a GA event's comes back {"offers": []} (TicketsData's capture of LCD Soundsystem)
              offersAnswered: !!(json && !Array.isArray(json) && Array.isArray(json.offers)) };
  for (const d of walkJson(json)) {
    if (Array.isArray(d.offers) && d.offers.some(o => o && Array.isArray(o.items) &&
        o.items.some(i => i && ("priceLevelID" in i || "sectionLabel" in i)))) s.offers = true;
    if (Array.isArray(d.offerPrices)) s.prices = true;
    if ("onSaleNow" in d || "onSaleStatus" in d || Array.isArray(d.deliveryMethods)) s.onsale = true;
  }
  return s;
}

// the page answered with seats (or, for a GA event, with a price book that carries availability)
function inventoryIn(captures) {
  let offers = false, answered = false, prices = false, flow = false;
  for (const c of captures) {
    if (!c.shape) continue;
    offers = offers || c.shape.offers;
    answered = answered || c.shape.offers || c.shape.offersAnswered;
    prices = prices || c.shape.prices;
    flow = flow || c.shape.onsale;
  }
  // the seat page's two inventory answers (TicketsData's routes offer_search + inventory_v4) are both in
  return { offers, prices, flow, complete: answered && prices };
}
