# Open Distribution in Primary Ticketing — Research Proposal

**Doc version:** v1.0.0 (2026-08-26)

**Status:** DRAFT — for committee recruitment. Not defended, not pre-registered yet.
**Instrument under test:** the Bridge ([`d4_bridge_charter.md`](d4_bridge_charter.md)) · **Endgame this formalizes:** [`d_tier_goals.md`](d_tier_goals.md) ("an open-distribution Ticketmaster")
**Governed by:** [`../CLAUDE.md`](../CLAUDE.md) rule 2 — upstream APIs are read-only until the operator authorizes a per-platform write carve-out. That rule is the field study's critical path (§10), not a footnote.

---

# PART I — THE TWO-PAGER

*Self-contained. This is what goes to a prospective committee member; Part II is the working apparatus behind it.*

## 1. The question

**Does opening primary inventory to multi-channel distribution raise a small venue's realized revenue per available seat, relative to gated single-channel primary — and under which pricing mechanism?**

Primary ticketing for small venues (200–2,000 capacity comedy clubs, community events, mid-tier music) is sold almost entirely through one gated channel: the venue's own page, or a platform that requires exclusivity. The inventory is invisible to the ~10 retail channels where discovery actually happens. The counter-position — **list once, sell everywhere, non-exclusive, venue keeps pricing and buyer data** — is the Bridge's product thesis and the object of this research.

Three sub-questions become chapters:

- **(a) Pricing.** Can clearing-price and sell-through-hazard models estimated on secondary-market data price *primary* inventory better than venue intuition? (Ch. 4)
- **(b) Distribution.** Does open distribution raise revenue per available seat, net of channel fees — or does it merely relocate the same buyers into fee-bearing channels? (Ch. 5)
- **(c) Mechanism.** Fixed posted price, scheduled markdown, or auction — which should a small venue actually run, given its demand uncertainty and its tolerance for unsold seats? (Ch. 6)

## 2. Why the question is genuinely open

The academic literature prices the *secondary* market and treats primary underpricing as a puzzle to explain (Krueger's concert-pricing work; Courty on resale; Leslie & Sorensen on resale welfare; Budish & Bhave on primary auctions capturing broker rents). The distribution *channel* is held fixed in nearly all of it. The practitioner world has run the reverse experiment — StubHub and others have moved into primary distribution — but publishes no revenue evidence, only press releases.

So the causal claim at the center of the product category (*open distribution raises seller revenue*) is asserted commercially and untested publicly. It is also non-obvious: channel fees are 10–25%, and if open distribution mostly re-routes buyers who would have bought anyway, the venue nets **less**. That is the null this study is built to be able to accept.

## 3. Why it can be answered here

Most theses on this question die for want of data. This one starts with a proprietary panel and a working instrument:

| Asset | What it is | Chapter |
|---|---|---|
| Cross-source event hub | `aq_event_map` (~7.3k events) resolving every marketplace's event id to one canonical key | 4, 5 |
| Listings tape | `event_listing_snapshot_daily` — 3 point-in-time slots/day, **indefinite** retention, per-source medians + cross-source blend | 4 |
| Seat-level feature store | `venue_section_price_daily` — one row per (event × venue-section × day), indefinite retention | 4, 6 |
| Realized sales | Order/sales tables retained **forever** across five marketplaces (`evo_orders`, `seatgeek_orders`, `tickpick_orders`, `vivid_orders`, `seatdata_sales_snapshots`) | 4 |
| Demand covariates | ESPN, weather, FRED macro, news-wire feeds joined on the same key | 4 |
| The instrument | The Bridge: a white-labeled primary storefront wired to the same distribution rails | 5 |

The unfair advantage is not the volume. It is that **the treatment and the measurement live in the same system**: the Bridge sells the seat and the panel records what every competing channel was asking at that moment.

## 4. What is measured

**Unit:** the event. **Primary outcome:** *net realized revenue per available seat (net-RevPAS)* — gross primary receipts minus channel fees and payment costs, divided by seats offered. **Secondary:** sell-through at door time; price realization vs. model clearing price; time-to-50%-sold; buyer-record capture rate.

**Treatment:** open distribution (primary inventory syndicated to N retail channels at a venue-set floor) vs. gated (venue's own page only). **Assignment:** event-level randomization within venue, staggered across venues, pre-registered before the first on-sale.

**The finding that would kill it:** net-RevPAS statistically indistinguishable across arms, or gross-up swamped by fees. That result gets written and published the same as any other (§13).

## 5. What the committee is for

Three to four external reviewers, quarterly, on the record: a **broker/marketplace operator**, a **primary/open-distribution practitioner**, and an **academic or quant** to attack the models. The role is real and narrow: read the chapter, tell me where it is wrong, hold the date.

## 6. Dates

| Milestone | When | Consequence |
|---|---|---|
| Proposal defense | 4 weeks | This document, defended live to the committee |
| Qualifying exam | Q1 | Ch. 4 results presented — models beat the venue-intuition benchmark, or they don't |
| Defense | 12 months | Bridge live at pilot venues, Ch. 5 results, presented to committee **plus one investor** |

---

# PART II — THE APPARATUS

## 7. Chapter map

| Ch. | Content | Dual use |
|---|---|---|
| 1 | Problem, setting, contribution | Pitch narrative |
| 2 | Literature: two-sided markets (Rochet–Tirole), primary-market mechanism design (Budish & Bhave), underpricing and resale (Krueger; Courty; Leslie & Sorensen), plus the practitioner record | The market section of the deck |
| 3 | Data and methods: the panel, its construction, its known defects (§9) | The data-room writeup |
| 4 | Clearing-price and hazard models backtested against realized sales | Calibration for the floor-price service |
| 5 | Field study: open vs. gated at N pilot venues | Traction |
| 6 | Market design: which mechanism a small venue should run | Product roadmap |
| 7 | Limits, external validity, what a larger N would settle | Honest close |

## 8. Identification

The hard constraint is N. A realistic pilot is **6–12 venues × 8–20 events each** — 100–200 events, not thousands. Three consequences, decided now rather than discovered later:

1. **Randomize within venue, not across venues.** Venue fixed effects absorb the enormous between-venue variance (capacity, genre, local demand). The comparison is event-to-event inside one room.
2. **Stagger adoption.** Venues enter on a pre-assigned schedule, giving a staggered difference-in-differences design with never-yet-treated events as controls, and guarding against a secular demand trend masquerading as a treatment effect.
3. **Pre-commit to the minimum detectable effect.** At this N, with event-level revenue variance in small-venue live events, the study is powered to detect **large** effects — on the order of 15%+ in net-RevPAS — not 3%. State the MDE in the pre-registration and state plainly that a null is a null *at that resolution*. A commercially decisive effect should be large; if the true effect is 4%, this design cannot see it and the thesis says so.

**Supplementary, non-experimental arm:** for pilot events that also appear on the resale tape, construct a synthetic control from matched panel events (same performer class, venue capacity band, day-of-week, lead time) and compare. This does not carry the causal weight — it is a consistency check on the experimental estimate and a way to use the panel's depth where the experiment's N is thin.

**Spillover.** Open distribution on one event can lift or cannibalize the venue's *other* events (attention, mailing list, calendar crowding). Randomizing within venue puts that spillover inside the control group and biases toward the null. Test for it by comparing treated venues' untreated events against never-treated venues' events; report it rather than assuming it away.

## 9. Measurement risks — the three that can invalidate the result

**(a) Primary inventory is largely unobservable in the existing panel.** The broker feeds are resale-only: SeatGeek's primary market is *not* visible through them (verified against a known SG-primary event), and face-value primary availability is observable only via AXS (`is_axs_primary`) and Ticketmaster (`td_tm_listings`, which is primary face value, not a resale floor). **Implication:** Ch. 4 cannot validate a primary clearing-price model on the panel alone. The model is *estimated* on secondary clearing behavior and *validated* on (i) the AXS/TM primary slice, and (ii) the pilot's own realized primary sales as they accumulate. This is the single largest methodological concession in the thesis and belongs in Ch. 3, stated first, not buried in Ch. 7.

**(b) Fees.** Gross revenue will almost mechanically rise under open distribution — more shelf space, more sales. The question is entirely about the *net*. Channel fee schedules must be captured per transaction (the order tables carry `order_fee_schedule`) and netted before the primary outcome is computed. A gross-revenue-only result is not a result.

**(c) Cannibalization vs. incrementality.** A buyer who would have bought on the venue's own page for a 0% fee, but instead buys on a channel at 15%, is a revenue *loss* dressed as a distribution win. Distinguish the two by buyer-record capture (new-to-venue vs. known-to-venue purchasers — the Bridge captures buyer identity on every channel by design) and by whether the venue's direct-channel volume falls in treated events.

## 10. Critical path — upstream write authorization

The distribution arm of the field study requires **creating listings on upstream platforms**. Repo-wide policy makes every upstream client GET-only by construction, and the Bridge charter §6.1 records the operator's status: *upstream stays read-only for now; revisit the carve-out when we decide to proceed.*

**No carve-out, no Ch. 5.** This is not a risk to monitor; it is a gate with a date attached:

- **Now → week 4:** decide the carve-out in principle, per-platform, with the operator. The engineering shape is already specified (sibling `*_listing_client.py` modules with the narrowest possible method allowlist, original read-only guards and their tests untouched, per-platform authorization).
- **If the answer is no by month 3:** Ch. 5 degrades to the observational arm — a matched-panel study of venues that already distribute openly versus those that don't. Weaker identification, still a thesis, and the degradation is declared in advance rather than improvised at the defense.

Ch. 4 and Ch. 6 have **no** dependency on the carve-out. They proceed regardless, which is why Ch. 4 is the qualifying exam.

## 11. Falsification

The thesis is committed to these in advance:

| Result | Reading |
|---|---|
| Net-RevPAS higher under open distribution, MDE-sized, robust to fee netting | Thesis supported; Ch. 6 asks which mechanism amplifies it |
| Gross up, net flat or down | **Open distribution is a discovery tool, not a revenue tool, at this venue class** — a publishable and commercially important finding |
| No difference in either | Null at this resolution; report the MDE and what N would settle it |
| Model clearing prices no better than venue posted prices | Ch. 4 fails; the floor-price service loses its justification and the product simplifies |

## 12. Calendar

| Week | Deliverable | Public form (§13) |
|---|---|---|
| 1 | Committee invited, dates held | Calendar invites sent |
| 4 | This proposal defended | Live session, written plan circulated in advance |
| 6 | Pre-registration filed (design, MDE, outcomes, analysis plan) | Timestamped, sent to committee |
| 8–14 | Ch. 3 (data + methods) and Ch. 4 (models) | Ch. 4 presented at the qualifying exam |
| 12–20 | Pilot venues signed; carve-out resolved (§10) | Status memo to committee |
| 20–44 | Ch. 5 field study runs | Interim results at the mid-point review |
| 44–50 | Ch. 6 mechanism findings | Circulated |
| 52 | Defense — committee plus one investor | Full document sent 2 weeks prior |

## 13. The two governance rules

**Rule 1 — a chapter is not done until it is public.** Public means: presented live to the committee, or circulated in writing to all of them, or posted. Written-but-unsent is unwritten. The whole point of the frame is importing external judgment on a schedule; without that it imports nothing.

**Rule 2 — the committee gets calendar invites this month, before any chapter writing begins.** Structure without witnesses is procrastination in academic regalia. Annex A is the email; it goes out before Ch. 2 gets a single paragraph.

**A third, implied by the first two:** every dated milestone in §12 exists to be missed *visibly*. A slipped date that no one external notices is not a date.

---

## Annex A — committee outreach email

> **Subject:** Advisor on a research project — open distribution in primary ticketing
>
> [Name] —
>
> I'm running a 12-month research project on a question I think you have direct evidence about: whether opening primary ticket inventory to multi-channel distribution actually raises a small venue's net revenue, or just moves the same buyers into fee-bearing channels.
>
> It's a real study, not a white paper. I have a proprietary panel — multi-marketplace listings and realized sales, point-in-time, cross-source keyed — and a working primary-ticketing product to run the field experiment through. The design is randomized at the event level within venue, pre-registered, with net revenue per available seat as the outcome.
>
> I'm assembling a review committee of three or four people. The commitment is one hour a quarter: read the chapter, tell me where it's wrong. Four sessions over twelve months, dates fixed now. The two-page proposal is attached.
>
> Would you sit on it?
>
> — Julian

*Send to: one broker/marketplace operator, one primary/open-distribution practitioner, one academic or quant. Send all invitations in the same week; hold the four dates before the first reply arrives.*

## Annex B — pre-registration skeleton (file by week 6)

1. **Hypotheses.** H1: net-RevPAS higher under open distribution. H2: effect increasing in the venue's baseline discovery deficit. H3: model-set floors outperform venue-set floors on realized revenue.
2. **Design.** Event-level randomization within venue; staggered venue entry; assignment fixed before on-sale and unchangeable thereafter.
3. **Outcomes.** Primary: net-RevPAS. Secondary: sell-through at door, time-to-50%, price realization vs. model clearing price, buyer-capture rate, direct-channel volume (cannibalization check).
4. **Sample and power.** Target N venues and events; stated MDE; stopping rule.
5. **Analysis.** Two-way fixed effects with staggered-adoption-robust estimator; venue-clustered inference; pre-specified covariates (capacity, genre, lead time, day-of-week, local demand index).
6. **Deviations.** Any departure logged, dated, and reported in Ch. 5 — including the §10 degradation path if the write carve-out is refused.

---

**Open items for the operator before week 4:** (i) the §10 carve-out decision; (ii) whether pilot venue identities and transaction-level results may appear in a document that leaves the company, and under what aggregation; (iii) whether the panel's proprietary detail (source list, coverage, retention) is disclosed at the level of Ch. 3 above or held back to a committee-only appendix.
