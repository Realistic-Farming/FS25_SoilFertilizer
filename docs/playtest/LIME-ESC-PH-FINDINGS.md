---
title: "Pack 03 findings — what was wrong and what we fixed"
owner: Wizard
created: 2026-08-29
audience: "Testers (plain English) + PR / ledger reviewers"
---

# What was wrong, and what we did

This is the story of the Auto lime + Esc pH map polish wave in plain English. You do not need code to use it.

## Player symptoms we were chasing

1. **Esc pH map looked “one flat green”** even when the second pass over the same ground had actually raised pH again. Mid-pass and overlap looked the same.
2. **Yellow / amber “teeth” or stripes** across a freshly limed strip (boom banding), so a single up-the-field pass did not look like one clean treatment.
3. **Whole headland looked hot** (or nothing looked specially hot), instead of only the places where the headland **crosses** the up/down passes — the way a real double coverage would look.
4. **Auto rate freezing or dropping** when you hired a helper and walked away (earlier in the wave; fixed before the final colour work).
5. **Over-limed orange/red** appearing when we did not want normal needy liming to hit that band.
6. **Colours too washed out** — pale greens that hid real variation under the Esc map blend.

## Root causes (plain English)

### A. Dose vs legend

For a while the **numbers in the log were already right** (first touch ~6.3, re-hit ~6.6) but the **map colours** used coarse bands and a soft two-step gradient. Mid and overlap sat in colours that looked almost the same through Esc’s semi-transparent overlay. Turning the lime rate alone could not fix “I cannot see the difference.”

### B. Accidental double paint inside one straight pass

To kill yellow boom seams we had briefly painted more often (half a map-cell of travel between stamps). That made consecutive boom stamps **overlap themselves** on the way up the field. The same ground got a second full dose mid-pass. Logs showed alternating ~6.29 and ~6.60 **while still going straight**. After we improved the colours, those doubles showed up as **amber teeth on green**.

### C. Soft ceiling too tight for real crossings

A safety ceiling near ~6.6 meant any second hit — whether a bad mid-pass double or a real headland cross — stopped at the same tint. Once mid-pass was already full of false doubles, **true crossings could not look uniquely hotter**.

### D. Wizard intent lock (final)

Hot colour should appear **only where the headland pass crosses the up/down passes** (true double coverage). The whole headland must not glow end to end. Mid up/down must read as a **single** treatment. Optimal should be a **deeper green**, bad ends a **deeper red**, with **more colour stages** so real spreader variation shows.

## What we changed (this playtest build)

| Change | Why |
|---|---|
| Per-pass pH cap set so first pass lands below the “looks optimal” band and a real second hit can cross it | Mid stays visibly different from a true double without slamming Over-limed |
| Soft ceiling raised enough that a genuine double (~6.7) can show, still under Over-limed | True crossings can read hotter than a single mid-pass |
| Boom travel gate restored to **one full map cell** (removed the half-step self-overlap) | Stops mid-pass double stamps that caused amber teeth |
| Continuous pH value→colour ramp + a **four-stop** deeper pH gradient on the Esc map (and matching legend) | Washed flat green → readable amber / green stages |
| Auto rate kept live for helper / unseated play (earlier fixes in the same wave) | Helper liming still meters while you walk away |
| Additive paint + ceiling clamp (no “fill to target” second pass that overshot) | Offered dose matches applied; no silent overshoot |

## What Wizard already accepted

On the workshop save, Wizard said the Esc map **looks perfect**. This pack asks other testers to confirm on their setups. If your map looks wrong, that is still a real report — say which job id and attach a screenshot.

## What “PASS” should feel like

- Straight limed lanes: **clean**, mostly one treatment colour (amber / early green for needy ground moving up) — **not** repeating amber zebra teeth.
- Where headland **crosses** those lanes: **clearly hotter / deeper green** only in the crossing footprints.
- Untreated acidic ground: deeper red / amber stages easy to tell apart.
- No surprise Over-limed orange from a normal Auto pass on needy ground.
- After **H** and walking away: Auto stays on and does not collapse below the needy floor while the field still needs lime.
