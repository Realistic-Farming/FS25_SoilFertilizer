---
title: "Playtest Pack 03 — Soil Fertilizer lime / Esc pH map"
owner: Wizard
status: ISSUED
created: 2026-08-29
build: "Soil Fertilizer wizard/lime-esc-ph-playtest-20260829 (PR into development) — use the zip or loose folder from that PR, not an older pre"
closes: "When Wizard calls the wave done or issues Pack 04"
---

# Playtest Pack 03 — Soil Fertilizer: Auto lime and Esc pH map

Thank you for helping. This pack is **only** about liming with Auto rate and reading the result on the Esc soil pH map. You do not need to know how the mod is coded.

## What this pack is checking

We spent a long workshop session fixing Auto lime so that:

- One straight pass of the spreader looks like a **single** treatment on the map (not striped “teeth”).
- Where a **headland pass crosses** an up/down pass, that crossing looks **hotter** (double coverage), like real life — **not** the whole headland glowing end to end.
- The Esc pH colours are **deeper and clearer** (stronger reds and greens, more steps), so real spreader variation is obvious.
- Auto rate keeps working after you hire a helper and walk away.
- The game does not paint “Over-limed” orange/red by mistake during normal needy liming.

Wizard eyes-on on the workshop save already called the map **perfect**. Your job is to confirm that holds on **your** machine, map, and play style, and to catch anything we missed.

## Two rounds

| Round | File | Jobs | Focus |
|---|---|---|---|
| **1** | [ROUND-1.md](ROUND-1.md) | **P3-01 … P3-12** | Happy path: Auto lime, mid-pass clean, true crossings hotter, colours, helper |
| **2** | [ROUND-2.md](ROUND-2.md) | **P3-13 … P3-24** | Edges: Precision Pack off/on, save/reload, MP if you can, empty tank, night, different boom |

Do **Round 1 first**. Only start Round 2 if Round 1 is mostly PASS / PASS WITH NOTES.

## Findings (please read once)

[FINDINGS.md](FINDINGS.md) explains in plain English **what was wrong** and **what we changed**. Use it if a result looks odd — it tells you what we already know so you do not re-report closed issues as brand new.

## Build to install

1. Install the Soil Fertilizer build from the **lime Esc pH playtest PR** (branch `wizard/lime-esc-ph-playtest-20260829`) — zip or loose mods folder as your team usually does.
2. Version on this wave is in the **2.5.0.x** line; confirm the PR description if unsure.
3. Prefer a **copy** of a save you can afford to lime hard on (acidic / needy field).
4. For Auto tests: use a lime spreader the mod supports, with Auto rate available.

## How to report

For each job, fill the result table:

| Outcome | Means |
|---|---|
| **PASS** | Did what the job asks |
| **PASS WITH NOTES** | Worked, but something felt off |
| **FAIL** | Did not do what the job asks, or crashed |

For anything that is not a PASS:

1. Note the job id (for example `P3-04`).
2. Say what you did, what you expected, what you saw.
3. Screenshot the Esc **Soil Layers → pH** map when the problem is visual.
4. Copy `Documents\My Games\FarmingSimulator2025\log.txt` **right after** the problem (the game overwrites it on next launch).
5. Open or comment on a GitHub issue on Soil Fertilizer and paste that report.

## Please do not re-report these as new bugs

| Already known / accepted | Notes |
|---|---|
| Wizard workshop save already looked “perfect” on Esc pH after this build | Still useful if **your** map looks different |
| Tiny offered vs applied differences of about one raw step | Quantisation; only fail if gaps are large or paint looks wrong |
| Precision Farming active stands Soil Fertilizer down | Expected; Round 2 has a job for that |

## Owner note (not for testers)

Pack issued by Ash on Wizard ask 2026-08-29. Ledger + PR carry the engineering findings. Lime repair DESIGN 19:50 was superseded by Wizard eyes-on PASS; this pack is confirmation for the wider tester group.
