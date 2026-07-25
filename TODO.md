# TODO: FS25_SoilFertilizer

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [x] Resolve Point 8 (ProStaff silent bridge): decided no bridge now; baseline v3 "already consumed" claim to be corrected by Claude(A) to planned-not-built.
- [ ] Confirm getFieldInfo should stay the sole companion read path; verify CropDisease and DairyCore call it (not `soilSystem.fields`) during their audits.
- [ ] Decide whether getFieldInfo exposes FieldSentry state or companions keep reading `g_currentMission.fieldSentry`.

## Bugs
- [ ] None open from the audit. Track new ones from GitHub issues here.

## Features / enhancements
- [x] Refined per-pixel value-map engine (WizardlyPayload's #736): adopted and folded into development (cd871bd7). Four merge-review fixes landed with it: migration coord fix, skipped-day batch-tail simulation, undiscovered-disease display-map gate, and the SoilMapOverlay semantic review. Per-cell spray now paints the value maps instead of the field average (#735). Our simulation kept on top of the storage engine.
- [x] Organic certification multiplayer sync (81d7f9d8): state serialized on every field path, fixing the co-op client wipe. Backed by an ephemeral 3-state status-map layer painted at cert changes (a54098f1) and surfaced as map layer 12. Answers the ecosystem organic-cert MP-sync open call.
- [x] No-till organic-matter dynamics (#738, f0f5aab8): per-tillage oxidation gradient + fenced no-till daily credit; the flat OM_BOOST retired.
- [x] Rotation planner v1 (#739): data surface publishes lastCrop3 + rotationBonusDaysLeft and blesses getCropFamily + the candidate pool (db315d5e); the in-menu rotation planner dialog ships on top (#744) alongside the FarmTablet app.
- [x] Short-month rain fill (#740, 790bc345): synthetic weather presets reshaped into a month-length effective-climate fill (short seasons get a rain top-up instead of drying out).
- [x] Harvest contract underwrite (#741, 02074f1d): stateless getCompletion override divides out the yield modifier so soil-reduced yields still let harvest contracts reach 100%.
- [x] Season-scaled chemical durations (SF-31, 9d624aef): fungicide and effect durations normalize on Time Guard's daysPerPeriod (REFERENCE_DPP=3).
- [x] Unscouted disease indicator (cb29b018): an unscouted field reads UNKNOWN rather than clean green (the first half of the progressive disease reveal below).
- [x] Compost amendment-burn cap (bed49d9c): finished compost caps at COMPOST_MAX, gentler than fresh slurry/manure. Pest/disease retune (#737) so thresholds are reachable and the strict tillage order holds.
- [x] Six physical fungicides (Propiconazole/Azoxystrobin/Boscalid/Mancozeb/Metalaxyl/Tebuconazole): buyable + sprayable IBC tanks routed into the catalog control math; kept in scout/recommend but gated out of instant-apply via `PHYSICAL_FUNGICIDES`. Shipped 2.4.7.0, verified in-game (buy / spray / scout). Kit data discarded as duplicate; SF catalog reused. (Sulfur/Copper extend the same way + `ORGANIC.APPROVED_INPUTS` when A-side's brief lands.)
- [x] Network event round-trip test harness (`tools/test/lua/network_events_roundtrip_test.lua` + mock stream in prelude): single-machine serialization desync coverage for all 13 events. The substitute for the two-machine MP test.
- [ ] NetworkSync v2 delta path: `onWriteDelta`/`onReadDelta` on SoilNetworkSyncBridge (send only changed fields).
- [ ] ProStaff fertilizer discount silent bridge (when scheduled): pcall-guarded `proStaffManager:getFertilizerDiscount(farmId)` as a cost multiplier at the fertilizer cost site.

## Cross-mod integration
- [x] StateLedger bridge (`SoilFertilizer_Soil`, delegate-when-present).
- [x] NetworkSync bridge (`SoilFertilizer_Sync`, whole-field-map).
- [x] MasterHUD bridge (soil HUD draw stack via subscribe).
- [x] SettingsHub bridge (settings mirrored for FarmTablet System Settings app).
- [ ] Lock module ids `SoilFertilizer_Soil` and `SoilFertilizer_Sync` with Claude(A) before release (persistence + wire keys, never rename after ship).
- [~] Two-machine MP sync test of the bridges: the LIVE two-machine test is out of scope (no dedicated-server budget). Substituted by the network round-trip harness (serialization desync coverage for all events) + single-host smoke. Ledger 2026-07-15.

## Docs / localization
- [ ] Keep all 26 languages in step for any new setting or fill type.
- [ ] Update SoilVersionDialog CHANGELOG + README version on every release.

## Blocked / waiting on
- [!] getFieldInfo FieldSentry-state decision (waits on: audit answer).
- [!] ProStaff discount bridge (waits on: ProStaffCoOp handle confirmed + SF cost hook site scheduled).
