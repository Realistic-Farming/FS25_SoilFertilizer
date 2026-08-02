# Roadmap: FS25_SoilFertilizer

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline.
> Forward-looking only. Shipped history lives in CHANGELOG.md and the releases.

## How to use this file
- Populate the milestones below from the audit baseline once it lands.
- Each item should be small enough to map to a `TODO.md` entry.
- Keep it honest: near-term is committed, mid-term is intended, long-term is aspirational.

## Current baseline
- Version at baseline: v2.4.7.0 (development); the pre-release testing cycle for the disease cluster + physical fungicides + the Refined engine adoption.
- Refined per-pixel value-map engine (WizardlyPayload's #736) adopted and merged into development (cd871bd7); our simulation runs on top of it. The old SoilLayerInstaller handshake is no longer required.
- Audit reference: ecosystem-dev-tracking Point 1-8 docs (baseline v3); CLAUDE-LOG.md through the 2026-07-24 spatial-soil drop
- Baseline date: 2026-07-08 (updated 2026-07-25)

## Near-term (next release cycle)
- [x] Spatial scouting walked mask (SF-26): on-foot walking reveals the trouble's pattern where you walked, per farm, fading after N in-game days. Server-authoritative sampling, per-farm storage in its own home, Time Guard aging, StateLedger persistence, NetworkSync delivery (each payload entry carries its own truth), and a read-time compose on the disease map that never touches the shared mirrors. Built on `development`; PR to main pending. Reading surface and the kneel/handful members build on top.
- [x] The handful read (SF-38): the frozen payload contract the Read the Dirt panel renders. One kneel, one payload, assembled from getters that all already ship, each clause carrying its honest grain (spot/cell/field) and its own gate. Pure assembly, zero writes; the material verdict takes the fill type from the caller because the ground-material layers are material-blind; diseaseKnown is cell-grain via the walked mask when a fresh cell exists. 35 assertions. PR to main pending. The kneel (SF-37) calls it after its reveal write.
- [ ] Adopt NetworkSync v2 sub-module delta: add `onWriteDelta`/`onReadDelta` to SoilNetworkSyncBridge so only changed fields sync instead of the whole field map.
- [!] 255 fill type cap (issue #755): Giants Engine hard cap, not our bug. 25 custom fill types + base game + DLC can exceed the limit. Design options: ship as-is, consolidate fill types, or degrade gracefully. See ecosystem ledger 2026-07-26 for recommendation (hybrid approach).
- [~] Two-machine MP verification of all four bedrock bridges: reframed 2026-07-15 - the live two-machine test is out of scope (no dedicated-server budget). A single-machine network round-trip harness now covers serialization desync for every event/bridge; single-host smoke on top. Registration already confirmed in-game.
- [ ] Lock the provisional module ids with Claude(A): `SoilFertilizer_Soil` (StateLedger) and `SoilFertilizer_Sync` (NetworkSync) before they ship in a release.

## Mid-term (this season)
- [ ] ProStaff fertilizer discount bridge (silent, pcall-guarded read of `getFertilizerDiscount`) once scheduled. Not built today by decision (Point 8).
- [x] Grass drying / rotting (issue #749): shipped as the ground-material family (SF-43 to SF-49, IDs SF-42 superseded). MATERIAL DOWN records how long material lies out, WHAT THE SKY DID carries wetness and the water record, THE HAY BET converts by condition, STRAW DOWN covers the combine swath, THE YARD LADDER handles bale condition. Built on `development` and merged to main in PR #767. Reading surface (SF-48, Wizard lane) still deferred by ruling.
- [ ] Decide whether `getFieldInfo` should expose FieldSentry state (isSleeping/isMeadow/contractMaskActive) instead of companions reading `g_currentMission.fieldSentry` directly.
- [ ] Emit a clean disease-at-harvest signal (pathogen id + pressure) for an external diseased-food/mycotoxin model. Data already retained on fieldData at harvest; expose it deliberately.

## Long-term / aspirational
- [~] Deeper agronomy passes as the sim matures (compaction, cover, rotation tuning) without breaking the one-yield-truth pillar. Progress: no-till OM gradient (#738) and the rotation planner (#739) landed this cycle; compaction and cover remain.
- [x] Per-pixel value-map parity: shipped via the Refined engine adoption (#736). The SoilLayerInstaller handshake is retired (the installer is no longer required).

## Cross-mod / ecosystem dependencies
- [ ] NetworkSync v2 delta adoption (blocks on: FS25_NetworkSync v2.0.0.0, now released; this is an opt-in on our side).
- [ ] getFieldInfo contract confirmation (blocks on: CropDisease and DairyCore audits confirming they call the API, not the internal table).
- [ ] ProStaff discount (blocks on: FS25_ProStaffCoOp `proStaffManager` handle + the SF-side cost hook site being scheduled).
- [ ] Soil moisture coupling: expose SF's per-field compaction + organic matter as a water-retention signal for SeasonalCropStress to modulate moisture stress (compaction sharpens wet/dry, OM buffers). PIPELINE, community-originated (nemrod153). Arrow-ownership call ANSWERED 2026-07-15 (Claude(A)): Option B + firewall - SCS stays moisture authority, SF read-only one-way, the loop is cut by single-writer discipline (matches SF's lean). SF's export half is now buildable; the SCS consumption half folds into the SCS #89 rebuild. Proposal: ecosystem-dev-tracking `systems/soil-moisture-coupling/README.md`.

## Deferred / parked
- Precision Farming integration: never. Permanent stand-down house rule, not a roadmap item.
- Grass FIELD crop parity (weed/pest/disease + OM/organic + yield-% for grass grown on a real field): SCOPED IN 2026-07-16 (was "parked by design"). New rule: meadow grass stays soil-aware only (out of those models), but grass on a managed FIELD participates like any crop. Build surface: re-gate the `not isGrass` skips (SoilFertilitySystem.lua:269 weed / 287 pest / ~324 disease) on meadow-vs-field using the FieldSentry `isMeadow` discriminator (SoilFertilitySystem.lua:3016) instead of fruit type, and give grass fruit types disease-susceptibility + yield-% values (balance pass). Feeds Feed Provenance (a grass FIELD then seeds disease automatically via the harvest bus). Meadow grass (no fieldId) stays neutral and out.
- Rotation Foresight v2: an at-the-drill / sowing pre-plant prompt. Needs a reachable sowing/pre-plant hook. v1 SHIPPED this cycle on the field-detail / scout / FarmTablet surface (#739 data surface + the in-menu rotation planner dialog #744 + the FarmTablet app); v2 (the sowing-time prompt) still needs the hook. (ledger OPEN A)
- Disease progressive reveal: a richer readout where the Disease track mirrors the intel ladder - blank unscouted, "present" once the dog flags it, full % + name once scouted. First half SHIPPED: the unscouted indicator (cb29b018) reads UNKNOWN instead of clean green. The "present once the dog flags it" middle rung and full per-field knowledge state in SoilHUD remain. (ledger, 2026-07)
- #740 World Climate selection UI: the player-facing climate picker for the short-month rain fill is in review as Wizard PR #747 (renames the control to World Climate, 4-chip picker, 26 languages). Merge lands the UI on the already-built mechanism.
