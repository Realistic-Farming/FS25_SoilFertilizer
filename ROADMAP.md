# Roadmap: FS25_SoilFertilizer

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline.
> Forward-looking only. Shipped history lives in CHANGELOG.md and the releases.

## How to use this file
- Populate the milestones below from the audit baseline once it lands.
- Each item should be small enough to map to a `TODO.md` entry.
- Keep it honest: near-term is committed, mid-term is intended, long-term is aspirational.

## Current baseline
- Version at baseline: v2.4.6.0 (development)
- Audit reference: ecosystem-dev-tracking Point 1-8 docs (baseline v3); CLAUDE-LOG.md bedrock-delegation entries 2026-07-08
- Baseline date: 2026-07-08

## Near-term (next release cycle)
- [ ] Adopt NetworkSync v2 sub-module delta: add `onWriteDelta`/`onReadDelta` to SoilNetworkSyncBridge so only changed fields sync instead of the whole field map.
- [~] Two-machine MP verification of all four bedrock bridges: reframed 2026-07-15 - the live two-machine test is out of scope (no dedicated-server budget). A single-machine network round-trip harness now covers serialization desync for every event/bridge; single-host smoke on top. Registration already confirmed in-game.
- [ ] Lock the provisional module ids with Claude(A): `SoilFertilizer_Soil` (StateLedger) and `SoilFertilizer_Sync` (NetworkSync) before they ship in a release.

## Mid-term (this season)
- [ ] ProStaff fertilizer discount bridge (silent, pcall-guarded read of `getFertilizerDiscount`) once scheduled. Not built today by decision (Point 8).
- [ ] Decide whether `getFieldInfo` should expose FieldSentry state (isSleeping/isMeadow/contractMaskActive) instead of companions reading `g_currentMission.fieldSentry` directly.
- [ ] Emit a clean disease-at-harvest signal (pathogen id + pressure) for an external diseased-food/mycotoxin model. Data already retained on fieldData at harvest; expose it deliberately.

## Long-term / aspirational
- [ ] Deeper agronomy passes as the sim matures (compaction, cover, rotation tuning) without breaking the one-yield-truth pillar.
- [ ] Per-pixel mode parity and richer SoilLayerInstaller handshake coverage.

## Cross-mod / ecosystem dependencies
- [ ] NetworkSync v2 delta adoption (blocks on: FS25_NetworkSync v2.0.0.0, now released; this is an opt-in on our side).
- [ ] getFieldInfo contract confirmation (blocks on: CropDisease and DairyCore audits confirming they call the API, not the internal table).
- [ ] ProStaff discount (blocks on: FS25_ProStaffCoOp `proStaffManager` handle + the SF-side cost hook site being scheduled).
- [ ] Soil moisture coupling: expose SF's per-field compaction + organic matter as a water-retention signal for SeasonalCropStress to modulate moisture stress (compaction sharpens wet/dry, OM buffers). PIPELINE, community-originated (nemrod153). Arrow-ownership call ANSWERED 2026-07-15 (Claude(A)): Option B + firewall - SCS stays moisture authority, SF read-only one-way, the loop is cut by single-writer discipline (matches SF's lean). SF's export half is now buildable; the SCS consumption half folds into the SCS #89 rebuild. Proposal: ecosystem-dev-tracking `systems/soil-moisture-coupling/README.md`.

## Deferred / parked
- Precision Farming integration: never. Permanent stand-down house rule, not a roadmap item.
- Grass/hay as a full crop (weed/pest/disease + yield-% parity): parked by design; grass stays soil-aware only.
- Rotation Foresight v2: an at-the-drill / sowing pre-plant prompt. Needs a reachable sowing/pre-plant hook; v1 ships on the field-detail / scout / FarmTablet surface and does not need it. (ledger OPEN A)
- Disease progressive reveal: a richer readout where the Disease track mirrors the intel ladder - blank unscouted, "present" once the dog flags it, full % + name once scouted. Post-rollout upgrade; needs per-field knowledge state in SoilHUD. (ledger, 2026-07)
