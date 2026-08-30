---
title: "Pack 03 Round 1 — twelve core jobs"
owner: Wizard
status: ISSUED
created: 2026-08-29
items: P3-01 … P3-12
---

# Round 1 — twelve core jobs

Do these in order if you can. Each job is written for a player, not a programmer.

**Before you start:** read [README.md](README.md) and skim [FINDINGS.md](FINDINGS.md). Install the playtest Soil Fertilizer build from the PR. Use a needy (acidic) field you can lime. Have a lime spreader ready. Esc → soil layers → **pH** is how you judge almost every visual job.

---

## P3-01 — Load and open the pH map

**What you need:** The playtest build installed; any save with fields.

**Steps**

1. Start the game and load your test save.
2. Confirm Soil Fertilizer is active (no Precision Farming taking over soil if you can help it for this round — Round 2 covers PF).
3. Open Esc (or your usual map / soil layers route) and select the **pH** soil layer.
4. Pan over untreated ground and over any already-worked ground.

**Expect**

- Map opens without a freeze or blank layer.
- Untreated acidic ground looks clearly warmer (deeper red / amber) than healthier ground — colours should feel richer than “all pale green.”

**Fail if**

- Crash, blank map, or every field looks the same washed colour.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-02 — Turn Auto lime on and see it stick

**What you need:** Lime spreader in cab; needy field.

**Steps**

1. Sit in the spreader on the field.
2. Turn **Auto** rate on the way you normally do for Soil Fertilizer (same control you use in day-to-day play).
3. Confirm the HUD / rate readout shows Auto is on (not stuck on a manual low gear).
4. Drive a few metres spreading.

**Expect**

- Auto engages and stays on while you drive.
- Rate does not instantly fall to “off” or an empty-looking zero while the field still needs lime.

**Fail if**

- Auto will not engage, or drops off as soon as you move.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-03 — First straight pass looks like one treatment

**What you need:** Auto on; Esc pH map open (second screen or pause-check mid-pass is fine).

**Steps**

1. Lime a long **straight** up (or down) pass across needy ground. Avoid overlapping your own previous tracks for this job.
2. Stop. Open Esc pH and look **only** at that strip.

**Expect**

- The strip reads as a **clean** band — mostly one treatment stage (often amber / early green on needy ground).
- You should **not** see repeating horizontal amber/yellow “teeth” or zebra stripes across the boom width of that single pass.

**Fail if**

- Clear repeating teeth / zebra across the straight pass, or the strip looks randomly speckled hot and cold every boom width.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-04 — Mid-pass is not already “max hot”

**What you need:** Same strip from P3-03 (or a new clean straight pass).

**Steps**

1. On Esc pH, compare the middle of that single pass to untouched ground beside it.
2. Mentally note: mid-pass should look **treated but not finished** — not the hottest green on the field yet.

**Expect**

- Mid-pass is clearly improved vs untreated, but **not** the same deep hot green you would reserve for a true double coverage.

**Fail if**

- A single pass already looks maxed-out hot green everywhere along the strip (with no second pass yet).

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-05 — Headland crossing is hotter only at the cross

**What you need:** At least one finished up/down strip; room to run a headland along the ends.

**Steps**

1. Run a **headland** pass that crosses the ends of your up/down strips (the way you would finish a field).
2. Open Esc pH.
3. Look carefully at (a) the crossing footprints, (b) the middle of the headland where it did **not** cross an up/down strip, (c) the mid straight passes.

**Expect**

- **Crossing footprints** look hotter / deeper green than the single mid-pass.
- The rest of the headland that only got one pass should **not** glow hot end-to-end.
- This matches real life: double coverage only where passes actually overlap.

**Fail if**

- Whole headland is uniformly hot, **or** crossings look no different from mid-pass, **or** mid-pass is already as hot as the crossings (so crossings cannot stand out).

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-06 — Helper stays liming after you walk away

**What you need:** Helper / course hire you trust; Auto on.

**Steps**

1. With Auto on and product in the tank, start the helper on the needy field (**H** or your usual hire).
2. Get out and walk away so you are not in the seat.
3. Watch the helper continue for at least one full length of the field (or two minutes of active spreading).
4. Glance at rate / Auto state when you can (HUD, or re-enter briefly).

**Expect**

- Helper keeps spreading.
- Auto does not die the moment you leave the seat.
- While the field is still needy, rate should not collapse below the needy floor you are used to (workshop used “never under about 0.60× while needy” as a guide).

**Fail if**

- Spreading stops for no tank reason, Auto clears on exit, or rate sits uselessly low while ground is still needy.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-07 — No false Over-limed on needy Auto work

**What you need:** Esc pH; normal Auto liming on needy ground (not dumping for fun).

**Steps**

1. After one or two sensible passes (including a headland cross if you did P3-05), scan the worked area on Esc pH.
2. Look for orange / red **Over-limed** style cells in the middle of normal work.

**Expect**

- Needy Auto liming should **not** paint Over-limed blotches across the strip.
- Untreated very acidic ground can still look “bad” red — that is fine.

**Fail if**

- Large Over-limed patches appear from ordinary Auto passes on ground that still needed lime.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-08 — Colour stages are easy to tell apart

**What you need:** A field with untreated + partly limed + crossed areas (after P3-03…P3-05).

**Steps**

1. On Esc pH, without zooming into numbers, judge by eye:
   - untreated needy
   - single-pass mid
   - true crossing
2. Also glance at the on-map legend / colour bar if shown.

**Expect**

- Those three stages are **obviously different** — deeper reds/ambers on the bad side, deeper greens toward good / double.
- Not everything collapsed into one pale green.

**Fail if**

- You cannot tell single-pass from untreated, or single-pass from crossing, even when you know where you drove.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-09 — Second up/down lap beside the first (adjacent, not stacked)

**What you need:** Room for a second straight pass **beside** the first (normal field pattern), not deliberately on top of it.

**Steps**

1. Lime the next bout beside the first, boom just kissing or with your normal overlap habit.
2. Check Esc pH along both bouts and the thin join.

**Expect**

- Each bout still reads mostly as a single treatment in its centre.
- Only the intentional boom overlap join may look a little hotter — that is normal physical overlap, not “teeth every few metres.”

**Fail if**

- Every bout is full of zebra teeth, or the whole pair cooks to max green after one pair of passes with no headland.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-10 — Tank empty behaviour is honest

**What you need:** Nearly empty lime tank (or run until empty).

**Steps**

1. Keep Auto on and spread until the tank is empty mid-field.
2. Watch HUD / spreading / map for a short moment after empty.

**Expect**

- Spreading stops or clearly shows empty — no silent “ghost liming” that keeps painting the map with no product.
- Auto may stay armed, but the ground should not keep rising with an empty tank.

**Fail if**

- Map keeps improving with a confirmed empty tank, or the game hard-crashes on empty.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-11 — Pause / Esc map while helper runs

**What you need:** Helper spreading; Esc pH.

**Steps**

1. With the helper liming, open Esc pH several times over a minute.
2. Close Esc and confirm the helper is still working.

**Expect**

- Map updates in a believable way (new paint appears where the boom went).
- Opening Esc does not permanently stall the helper or freeze the client.

**Fail if**

- Freeze/hang on Esc, or helper dead after closing the map.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-12 — Round 1 gut check (Wizard bar)

**What you need:** Everything you have limed this session.

**Steps**

1. Stand back on Esc pH and ask: “Does this look like a real spreader job — clean passes, hotter only where I truly overlapped, colours I can read?”
2. Write a short plain-English note either way.

**Expect**

- Same feeling Wizard had on the workshop save: map looks **right**.

**Fail if**

- You would not show this map to another farmer as “working as intended.”

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## Round 1 summary

| Job | Result (PASS / NOTES / FAIL) | Issue link |
|---|---|---|
| P3-01 |  |  |
| P3-02 |  |  |
| P3-03 |  |  |
| P3-04 |  |  |
| P3-05 |  |  |
| P3-06 |  |  |
| P3-07 |  |  |
| P3-08 |  |  |
| P3-09 |  |  |
| P3-10 |  |  |
| P3-11 |  |  |
| P3-12 |  |  |

Tester name: _______________  
Date: _______________  
Save / map: _______________
