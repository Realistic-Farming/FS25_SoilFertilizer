# Vision: FS25_SoilFertilizer

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit (Point 1-8 docs, ecosystem-map, baseline v3).
> Last updated: 2026-07-08

## 1. One-line purpose
Per-field agronomy for FS25: it tracks Nitrogen, Phosphorus, Potassium, Organic Matter and pH for every field, with crop-specific depletion, fertilizer replenishment, weeds/pests/disease pressure, compaction, weather and seasonal cycles, and a yield forecast, so how you manage a field matters over seasons.

## 2. Problem it solves
Vanilla FS25 soil is a single binary "fertilized" state with no depletion, no rotation logic, and no long-term soil health. There is no reason to rotate crops, add organic matter, lime for pH, keep cover, or manage compaction. SoilFertilizer adds the persistent agronomy layer that makes those decisions pay off, or cost you, across a save.

## 3. Design pillars
- **Realism through agronomy.** Real N/P/K/pH/OM behaviour, crop-specific extraction rates, rotation bonuses and fatigue, fallow recovery, rain leaching, seasonal nitrogen.
- **One yield truth.** A single shared yield helper drives both the simulation and the Soil Monitor, so the number the player sees is the number the field uses. No duplicated formula, no monitor drift.
- **Standalone-first, ecosystem-aware.** Ships and runs fully on its own. Where a bedrock mod is present it delegates (delegate-when-present); it is never a hard dependency of any other mod and never hard-depends on one.
- **Zero Precision Farming, permanently.** SoilFertilizer detects PF only to stand down. No PF compatibility is ever built. House rule.
- **Multiplayer-correct, admin-authoritative.** Server owns the sim; settings changes are admin-gated; clients mirror server state.

## 4. Role in the ecosystem
- Public handle on `g_currentMission.soilFertilityManager`. The companion read contract is `soilFertilityManager.soilSystem:getFieldInfo(fieldId[, x, z])` (nil-safe, always-present return table; optional world position for per-cell zone data). Callers pcall-guard and gate on the handle. Never read `soilSystem.fields[fieldId]` directly.
- Reads from (consumes):
  - **SoilLayerInstaller** per-pixel density layers (soilN/P/K, pH, OM, pressures). When present, SoilFertilizer switches from field-average to per-pixel mode. This is the one hard internal handshake: the layer names must match on both sides or per-pixel mode silently stays off.
  - **ProStaffCoOp** `getFertilizerDiscount()` fertilizer discount: PLANNED, not built (see Point 8). Not consumed today.
- Read by (consumers): FarmTablet SoilFertilizerApp (nutrients + FieldSentry view), CropDisease, DairyCore, and any future companion, all through `getFieldInfo`.
- Core-API registration status (all four wired, delegate-when-present, 2026-07-08):
  - StateLedger (save/load): **yes**, module `SoilFertilizer_Soil` (soilData.xml kept as safety copy).
  - NetworkSync (MP state): **yes**, module/channel `SoilFertilizer_Sync` (whole-field-map; v2 sub-module delta adoption is a pending optional follow-up).
  - MasterHUD (overlays): **yes**, whole soil HUD draw stack registered via subscribe.
  - SettingsHub (admin settings): **yes**, all settings mirrored for the FarmTablet System Settings app.

## 5. Explicit non-goals
- No Precision Farming integration, ever (detect-to-stand-down only).
- Grass/hay is soil-aware (yield reacts to N/P/K + OM). The weed/pest/disease + yield-% rule is scoped to the land type (decision 2026-07-16): grass on a base-game MEADOW (no fieldId, no managed soil) stays out of those models, but grass grown on a real FIELD (has a fieldId, managed soil, can hold an organic cert) is a managed crop and participates in the disease + OM/organic models like any field crop. The field-grass parity build is tracked in ROADMAP; no parity promise for meadow grass.
- No ownership of the wider economy. SoilFertilizer charges fertilizer cost only; income, tax, markets and depots are their own mods.

## 6. Success criteria
- Field-management decisions (rotation, amendments, cover, lime, compaction relief) have visible, multi-season consequences on yield.
- The Soil Monitor number always equals the simulated field-average yield modifier (no drift).
- Multiplayer clients see the same field state the server holds, on join and on every change.
- The mod runs standalone with unchanged behaviour, and delegates cleanly when any of the four bedrock mods are installed.

## 7. Open questions for the audit
- Should `getFieldInfo` expose FieldSentry state (isSleeping, isMeadow, contractMaskActive)? Today companions read `g_currentMission.fieldSentry` directly. Confirm sufficient or fold into the read table.
- ProStaff fertilizer discount bridge: when is it scheduled? Baseline v3 wrongly said "already consumed"; corrected to planned-not-built (logged for Claude(A)).
- Confirm CropDisease and DairyCore call `getFieldInfo` rather than reaching into `soilSystem.fields` directly (verify during their audits).
