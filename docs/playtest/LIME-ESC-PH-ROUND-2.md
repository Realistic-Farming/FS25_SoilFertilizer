---
title: "Pack 03 Round 2 — twelve edge / regression jobs"
owner: Wizard
status: ISSUED
created: 2026-08-29
items: P3-13 … P3-24
depends_on: "Finish Round 1 first unless Wizard says otherwise"
---

# Round 2 — twelve edge and regression jobs

Only start this round when Round 1 is mostly clear. These jobs try to break the happy path.

---

## P3-13 — Save, quit to menu, reload

**Steps**

1. After a visible liming session (ideally with a crossing), save.
2. Quit to the main menu (or fully exit the game once).
3. Reload the same save.
4. Open Esc pH and find the same field.

**Expect**

- Painted pH pattern is still there (not wiped blank, not randomly reshuffled).
- Colours still readable.

**Fail if**

- Liming progress vanished, corrupted, or the map layer is gone.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-14 — Manual rate vs Auto on the same field

**Steps**

1. On a needy patch, run a short pass with Auto **off** at a fixed manual rate you choose.
2. On a neighbouring needy patch, run Auto.
3. Compare Esc pH behaviour and whether Auto still only “works while seated” (it should work either way for paint; Auto should meter).

**Expect**

- Both paint the map.
- Auto still shows living rate changes; manual stays where you set it.

**Fail if**

- Manual paints but Auto does not (or the reverse) with no other explanation (empty tank, wrong product).

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-15 — Precision Farming present (stand-down)

**Steps**

1. If you can, enable Precision Farming with Soil Fertilizer still installed (or use a save that already has both).
2. Check whether Soil Fertilizer soil / lime behaviour stands down as designed for your build.
3. Note what the pH map / liming does.

**Expect**

- Document what happens honestly. Designed stand-down is a **PASS** if Soil Fertilizer clearly yields and does not fight PF.
- If both fight and corrupt the map, that is a **FAIL**.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-16 — Multiplayer client eyes (if you have a partner)

**Steps**

1. Host or join with two players.
2. One player liming with Auto; the other watches Esc pH (or the field).
3. Confirm the watcher sees paint appear in a believable way.

**Expect**

- Client sees liming progress without needing a full relog for every metre.
- No desync where host map is limed and client stays barren forever.

**Fail if**

- Permanent desync, or client crash on paint.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-17 — Dedicated server (if you use one)

**Steps**

1. Same liming routine on dedicated.
2. Open Esc pH as a connecting client after some helper liming has happened.

**Expect**

- Join sees the field state without a long broken blank layer.
- No server hitch that kicks everyone when Esc opens.

**Fail if**

- Join never receives soil paint, or server dies when someone opens pH.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-18 — Night / rain / poor visibility

**Steps**

1. Lime a short pass at night or in heavy rain.
2. Check Esc pH (map lighting is separate from world lighting).

**Expect**

- Map colours still readable in the Esc UI.
- Spreading still functions.

**Fail if**

- Esc pH unreadable black/blank only at night, or spreading broken only in rain with no other cause.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-19 — Different boom width

**Steps**

1. If you own two lime tools with clearly different working widths, repeat a short Auto straight pass with each.
2. Compare Esc pH strip width and cleanliness.

**Expect**

- Wider boom paints a wider strip; both should stay free of zebra teeth on a single pass.

**Fail if**

- Only one width looks correct and the other is striped or over-hot mid-pass.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-20 — Deliberate triple overlap stress

**Steps**

1. On a small patch, drive over the **same** ground three times on purpose with Auto.
2. Watch Esc pH and whether Over-limed appears.

**Expect**

- Ground gets hotter each sensible re-hit until the soft ceiling / Over-limed rules kick in.
- Over-limed is allowed here if you truly stacked too much — say so in notes.
- Should not explode into random checkerboards far off the path you drove.

**Fail if**

- Paint splatters far outside your tracks, or the game crashes.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-21 — Courseplay / Autodrive helper (if you use it)

**Steps**

1. Send a CP/AD job with Auto lime on a needy field.
2. Watch one headland + one up/down in Esc pH afterward.

**Expect**

- Same visual rules as Round 1: clean mid, hotter true crosses.
- Helper does not leave mysterious untreated stripes that match “teeth” from the old bug.

**Fail if**

- CP/AD uniquely reintroduces zebra teeth or kills Auto every time (with log attached).

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-22 — After refill mid-field

**Steps**

1. Empty or nearly empty mid-pass, refill at the shop/tank, return to the same strip.
2. Continue Auto liming.
3. Check Esc pH for a weird doubled scar only at the refill join.

**Expect**

- Work continues cleanly; join may be slightly hotter if you overlapped, but not a broken texture.

**Fail if**

- Huge hot rectangle at refill, or Auto dead after refill until a full restart.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-23 — Log sanity (optional but valuable)

**Steps**

1. Enable or watch whatever Soil debug / log lines your build prints for lime offered vs applied (workshop used paired raw numbers).
2. During a clean straight pass, note whether offered and applied stay in step.

**Expect**

- No huge lasting gap (offered keeps climbing while applied never moves).
- Tiny one-step differences can be normal — only fail big lies.

**Fail if**

- Persistent offered≫applied with no map change, or spam errors in `log.txt`.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## P3-24 — Round 2 ship call

**Steps**

1. After Round 1 + Round 2, answer: “Would you ship this lime + Esc pH behaviour to players this week?”
2. List the top three remaining worries in plain English (or “none”).

**Expect**

- A clear yes / yes-with-notes / no, with reasons.

| Result | Notes / link to issue |
|---|---|
|  |  |

---

## Round 2 summary

| Job | Result (PASS / NOTES / FAIL) | Issue link |
|---|---|---|
| P3-13 |  |  |
| P3-14 |  |  |
| P3-15 |  |  |
| P3-16 |  |  |
| P3-17 |  |  |
| P3-18 |  |  |
| P3-19 |  |  |
| P3-20 |  |  |
| P3-21 |  |  |
| P3-22 |  |  |
| P3-23 |  |  |
| P3-24 |  |  |

Tester name: _______________  
Date: _______________  
Save / map: _______________  
MP / dedicated used?: _______________
