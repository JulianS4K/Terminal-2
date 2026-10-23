# Auto Pricer Field Guide

> **Doc version:** v1.0.0 (2026-10-23) — imported from the operator-supplied "Auto_Pricer_Field_Guide.docx"; served to the internal MCP tier as `s4k://auto-pricer-guide` and summarised in the `auto_pricer_setup` tool. Our data counterpart: `mcp_auto_pricer_setup(event_id)` (mig `20261023055000`) — SG2..SG6+ checked against EVO and GoTickets, row surge %, floors from the cheapest source.

Practical guide to Dumb Pricing, Smart Pricing, quantity markets, spacing, safeguards, and rule design

> **Scope of this guide.** This document summarizes the pricing behavior observed in the Auto Pricer interface and the working logic developed from live screenshots and preview behavior. It intentionally excludes any team-specific schedule, event grades, or team-specific pricing recommendations. Fields marked “Needs verification” are plausible interpretations that should be confirmed with a controlled Preview Pricing test before being used as hard rules.

## 1. How to Think About the Auto Pricer

The Auto Pricer is best understood as four layers: market anchor, quantity logic, inventory grid, and safety/automation controls.

Dumb Pricing is a simpler market-following engine. It starts from a selected SeatGeek quantity market and builds a ranked price ladder from that base.

Smart Pricing treats quantity buckets separately (pair, 3-pack, 4-pack, 5-pack, 6+), allowing the price of a large contiguous pack to follow a different market than a pair.

Section/row surge is a separate value layer. It lets a better row command a premium even when all listings are in the same zone.

Spacing settings control how tightly or widely your own inventory is distributed. This matters when you hold substantial inventory and do not want dozens of listings stacked at nearly the same price.

Safeguards such as floors, ceilings, top-of-range limits, and max single-step drop help prevent accidental overreaction to noisy market moves.

## 2. Core Terminology

| Term | Working definition |
|---|---|
| Zone Pricing | The zone/bucket being priced (for example, a lower-bowl or upper-bowl category). Each zone can use different settings. |
| SG2 | SeatGeek market for 1–2 tickets / pair market. |
| SG3 | SeatGeek market for 3-ticket listings. |
| SG4 | SeatGeek market for 4-ticket listings. |
| SG5 | SeatGeek market for 5-ticket listings. |
| SG6+ | SeatGeek market for 6 or more tickets; may include 6-, 8-, 10-, 12-ticket or larger contiguous packs. |
| Base Price | The market-derived starting point from which the pricer builds the zone’s price grid. |
| Delta | Adjustment to the selected market anchor. In observed Dumb Pricing behavior, a positive 1% delta produced a price approximately 1% below the selected market. |
| Spacing | The intentional separation between your own ranked listings. |
| Surge | Percentage premium applied to specified rows and/or sections to recognize better inventory quality. |
| Top of Range | A cap on how far the main price ladder can extend above its base, subject to interaction with other rules. |
| Floor / Ceiling | Absolute minimum and maximum price safeguards. |

## 3. Dumb Pricing

Dumb Pricing is the simpler engine. It is useful when the quantity markets are compressed, when the main objective is to stay competitive and move inventory, or when a zone does not need pack-specific logic.

| Field | Best current understanding |
|---|---|
| Base Listings | Selects the SeatGeek quantity market used as the anchor. Common observed setup: SG2. |
| Delta Type | Chooses whether the market adjustment is expressed as a percentage or a dollar amount. |
| Delta | Observed example: SG2 at $42.13 with Delta Type “%” and Delta 1.00 produced about $41.71, which is approximately 1% below SG2. |
| Redo Order | Appears to re-rank inventory on each run so the worst-to-best ordering stays current. Recommended to keep ON unless there is a reason to preserve an old order. |
| Row Ranking Method | Controls how row labels are interpreted for ranking. “Single-letter” appears to be the current row parsing/ranking method. |
| Sort Direction | “Worst to Best” means cheaper positions in the ladder begin with weaker inventory and step upward toward better inventory. |

> **Confirmed behavior — Delta.** In the observed Dumb Pricing example, SG2 = $42.13 and a 1.00% delta produced a low price of roughly $41.71. That is consistent with pricing 1% below the SG2 market. This is one of the clearest reverse-engineered behaviors in the interface.

## 4. Smart Pricing

Smart Pricing is quantity-aware. Instead of allowing a pair market to drag every listing to the same base, it maintains separate pricing logic for each quantity bucket.

| Bucket | Typical inventory governed |
|---|---|
| SP Qty1–2 / SG2 | 1–2 tickets |
| SP Qty3 / SG3 | 3 tickets |
| SP Qty4 / SG4 | 4 tickets |
| SP Qty5 / SG5 | 5 tickets |
| SP Qty6 / SG6+ | 6 or more tickets |

| Smart Pricing field | Best current understanding |
|---|---|
| SGx Enabled | Appears to turn on the matching SeatGeek quantity market for that inventory size. |
| Delta Type | Percentage or dollar adjustment for that quantity bucket. |
| Delta | Adjustment applied to the matching quantity market. Current default values appear to be 1.00; exact sign behavior should be confirmed in Preview Pricing. |
| Spacing | Quantity-specific spacing adjustment. Current screenshots show $0.00. Best used only after confirming where it is inserted in the calculation. |
| Previous Run Price | Stores the prior calculated base for each quantity bucket, confirming that Smart Pricing maintains independent quantity-level price states. |
| Min Price % from SG2 | Likely a lower guardrail relative to the SG2 market for larger quantity buckets. Needs verification. |
| Max Price % from SG2 | Likely an upper guardrail relative to SG2 so an abnormal pack market cannot send pricing too high. Needs verification. |

> **Why Smart Pricing matters.** A large contiguous pack may have different scarcity and buyer value than a pair. If SG2, SG3, SG4, SG5 and SG6+ are materially separated, Smart Pricing can protect that value. If all quantity markets are nearly identical, the added complexity may offer less benefit.

## 5. Market Diagnostic Columns

| Column | How to read it |
|---|---|
| Current SG2 Base Price | Live pair-market anchor. |
| Current SG3 Base Price | Live 3-pack anchor. |
| Current SG4 Base Price | Live 4-pack anchor. |
| Current SG5 Base Price | Live 5-pack anchor. |
| Current SG6 Base Price | Live 6+ pack anchor. |
| Current Base Price | Base currently being used by the zone. |
| Previous Run Price | Base price from the prior cycle. |
| Base Change | Dollar movement from prior base to current base. |
| Base Change Percentage | Percent movement from prior base to current base. |

A useful habit is to read the SG2→SG6+ sequence as a “quantity curve.” A flat curve means pack size is not commanding much premium. A widening curve suggests larger packs are scarce and may deserve separate Smart Pricing treatment.

## 6. Grid Constraints and Price-Ladder Controls

| Setting | Purpose / working interpretation |
|---|---|
| Price Floor | Absolute bottom price. Prevents the pricer from dropping below a chosen number even if the market moves lower. |
| Price Ceiling | Absolute upper limit. Useful when surge or market movement could create unrealistic high prices. A value of $0 may mean “no ceiling” in the current system. |
| Top of Range | Appears to limit how far the main price ladder can extend above the base price. Exact interaction with surge should be tested. |
| Minimum Spacing | Smallest allowed separation between ranked listings. Tighter settings create a denser grid; wider settings reduce self-competition. |
| Maximum Spacing | Largest allowed separation between adjacent ranked listings. Prevents the grid from becoming too sparse. |
| Total Prime Percentage | Meaning not yet established. Leave unchanged until verified. |

## 7. Section/Row-Specific Pricing (“Surge”)

Section/Row-Specific Pricing lets you assign a percentage premium to a row range, and optionally a section range. This is how the pricer can recognize that front rows are intrinsically worth more than back rows even inside the same zone.

Surge is percentage-based in the observed interface.

Because the base price changes from event to event, the same percentage can represent very different dollar premiums. For example, +100% on a $10 ticket adds $10, while +100% on a $50 ticket adds $50.

For practical rule design, it is often easier to think in dollars first (“I want this row about $12 above the back row”) and then convert that desired dollar premium into a percentage.

Upper-bowl and lower-bowl surge curves should generally be built separately. Cheap upper markets may require large-looking percentages to create modest dollar separation.

Avoid overlapping row ranges unless you know exactly how the engine resolves overlaps. A row should normally appear in one surge bucket only.

> **Dollar-to-percent conversion.** If Base = B and you want a target row price T, Surge % = ((T ÷ B) − 1) × 100. Example: $10 base and $22 target = ((22/10)−1)×100 = 120% surge.

## 8. Market-Movement Safeguards

| Control | Purpose |
|---|---|
| Max Single Step Drop | Appears to limit how far price can fall on a single Auto Pricer run. Example interpretation: a 1% setting would let a $100 price fall only to about $99 on one cycle, even if the raw market signal suggests a much larger drop. Needs a controlled test for exact behavior. |
| Floor | Hard-stop downside protection regardless of market calculation. |
| Ceiling | Hard-stop upside protection. |
| Min/Max Price % in Smart Pricing | Likely quantity-level guardrails against bad or thin market signals. Needs verification before broad use. |

## 9. Repricing Frequency / Scheduled Runs

The observed schedule uses different refresh frequencies as the event approaches:

| Time to event | Observed run interval |
|---|---|
| 7+ days | Every 8 hours |
| < 7 days | Every 3 hours |
| Same day after 9:00 | Every 10 minutes |
| Last 2 hours | Every 2 minutes |

Frequent checking does not have to mean aggressive price movement. The pricer can monitor the market often while a max-step-drop rule, floors, or wider spacing keep the actual price changes controlled.

## 10. Inventory and Sales Telemetry

| Metric | How it helps |
|---|---|
| Qty Open | How much inventory remains in the zone. |
| Qty Sold | Total sold quantity. |
| % Sold | Share of original inventory already sold. |
| Qty Sold Today | Very recent sales velocity. |
| Qty Sold Last 7 Days | Short-term demand velocity. |

These fields should influence how aggressive a zone is, even if the Auto Pricer does not automatically incorporate them into the formula. A zone with heavy open inventory and weak recent velocity should normally be treated differently from a nearly sold-through zone.

## 11. Administrative / Audit Fields

| Field | Purpose |
|---|---|
| Modified By / Modified Date | Who last changed the rule set and when. |
| Last Run Date / Last Run By | Who or what last executed pricing. |
| Next Run Time | Next scheduled repricing cycle. |
| Base Price Synced At | When Smart Pricing quantity bases were last synchronized. |
| SGEvent ID | SeatGeek event identifier tied to the event. |
| Active? | Whether Auto Pricing is enabled for that zone. |
| Status | Appears to be a run/state field; exact meaning depends on values displayed. |

## 12. General Rule-Design Framework by Event Tier

The Auto Pricer can be standardized with a tier-based approach. The exact numbers should be calibrated to each market, but the directional logic is useful across teams and events.

| Tier | Typical engine | Primary objective | General grid behavior |
|---|---|---|---|
| Tier 5 | Dumb Pricing | Move inventory quickly | Very tight grid, aggressive market-following, limited protection |
| Tier 4 | Smart Pricing | Move volume intelligently | Thin/tight grid, modest pack protection, controlled row premiums |
| Tier 3 | Smart Pricing | Normal healthy sell-through | Balanced spacing, normal row curve, moderate quantity differentiation |
| Tier 2 | Smart Pricing | Sell while preserving upside | Wider spacing, stronger low-row/pack protection, slower downward reaction |
| Tier 1 | Smart Pricing | Protect premium value while still selling | Widest thoughtful grid, meaningful quantity/row protection, stronger floors/guardrails |

The key point is that “better tier” does not mean “do not sell.” It means the pricer is allowed to protect scarce inventory more aggressively while still maintaining enough price points to transact.

## 13. Reverse-Engineering / Testing Protocol

For fields whose exact formula is not documented, use Preview Pricing as a controlled experiment. Change only one variable at a time.

Pick one event and one zone with several rows and multiple quantities.

Record the current SG2/SG3/SG4/SG5/SG6+ base prices and the current Preview Pricing output.

Change exactly one field (for example, Qty4 Min Price %, Top of Range, or Qty6 Spacing).

Run Preview Pricing again without changing anything else.

Compare which listings changed and by how much.

Repeat once more with a larger test value if the behavior is still ambiguous.

Only after the formula is clear should the setting be copied to multiple events.

## 14. Confidence Map

| Behavior | Confidence |
|---|---|
| SG2/SG3/SG4/SG5/SG6+ represent quantity-specific SeatGeek markets | High |
| Dumb Pricing Delta 1% can produce roughly 1% below the selected market | High (observed example) |
| Smart Pricing keeps independent quantity-level previous prices | High (visible fields) |
| Section/row surge is percentage-based | High |
| Price Floor / Price Ceiling are absolute safeguards | High |
| Scheduled cadence changes as the event gets closer | High |
| Max Single Step Drop limits one-cycle downside | Medium-high; formula should be tested |
| Top of Range limits the main ladder above base | Medium; interaction with surge needs testing |
| Smart Min/Max Price % are SG2-relative guardrails | Medium; needs controlled test |
| Smart quantity Spacing is an additive pack-specific adjustment | Medium-low; needs controlled test |
| Total Prime Percentage | Unknown; needs documentation or UI test |

## 15. Quick Setup Checklist

Choose Dumb vs Smart Pricing based on whether quantity markets materially differ.

Confirm the zone’s market anchor and Delta behavior.

Set an appropriate Floor (and Ceiling only if needed).

Choose Top of Range plus Min/Max Spacing to control how dense the grid should be.

Build row/section surges separately for upper and lower inventory where appropriate.

Review Qty Open, % Sold, Sold Today, and Sold Last 7 Days before copying rules blindly.

For Smart Pricing, verify each enabled quantity bucket and its delta/guardrails.

Preview before updating live sell prices.

Use Copy Rules to Multiple Events only after the template has been tested on representative inventory.

Monitor Base Change and quantity curves after activation to ensure the rules react as intended.
