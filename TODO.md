# TODO: FS25_SoilFertilizer

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [x] Resolve Point 8 (ProStaff silent bridge): decided no bridge now; baseline v3 "already consumed" claim to be corrected by Claude(A) to planned-not-built.
- [ ] Confirm getFieldInfo should stay the sole companion read path; verify CropDisease and DairyCore call it (not `soilSystem.fields`) during their audits.
- [ ] Decide whether getFieldInfo exposes FieldSentry state or companions keep reading `g_currentMission.fieldSentry`.

## Bugs
- [x] 2026-07-26 bug sweep (54 total across ecosystem): SoilFertilizer bugs fixed and merged to main. See GitHub issues #748-#757 for individual tracking. All closed.
- [x] Oilseed-radish nitrate by direct drill (issue #778): the crop-incorporation probe never ran on seeders, so terminating a cover crop with a direct drill (Väderstad Proceed V24) awarded only the flat DIRECT_DRILL residue and the nitrate HUD read "unchanged". Fixed by installing the #674 crop-biomass probe on `SowingMachine`, threading `_sfCropBiomass` into `onSowing`, and awarding the new `CROP_INCORPORATION.SOWING` profile (OM 0.4 / N 2.0 / P 0.4 / K 1.2) after the residue block, gated on `residueIncorporation` and biomass > 0. 20 assertions in crop_incorporation_sowing_778_test.lua. **Merged to main in PR #781.**
- [x] Tractor side-tank NPK credit (issue #780): the credit died silently once the planter's liquid tank drained - `getActiveSprayType` returned nil, `getSprayerFillUnitIndex` fell back to a wrong-but-valid local unit (seed tank / second product tank), and `resolveSprayerFillTypeIndex` returned that local product, failing the nutrient-profile check. Fixed with an external-source guard (`wap.sprayVehicle ~= sprayer` -> wap.sprayFillType is authoritative) plus a recognized-product fallback to `wap.sprayFillType` with a debug log in the sprayer hook. 9 assertions in resolve_sprayer_filltype_780_test.lua. PR open.
- [ ] None open from the audit. Track new ones from GitHub issues here.

## Features / enhancements
- [~] Text fitting helper for raw renderText (SF #771): `UIHelper.fitText(text, size, maxWidth, minSizeFactor, ellipsis)` returns fitted text plus the size to draw at, mirroring TextElement RESIZE. `UIHelper.renderTextFitted` is the drop-in for a renderText call with a known width. `SoilSettingsPanel:drawText` takes an optional `maxWidth` and is wired. 38 assertions in text_fitting_771_test.lua. Also added `getfenv`/`setfenv` shims to the test prelude, since FS25 is Lua 5.1 and the harness is fengari 5.3, and UIHelper publishes its handle via `getfenv(0)`.
- [ ] Adopt the fitting helper in the remaining raw renderText surfaces (#771 follow-up): `SoilHUD.lua` (31 calls, the surface actually in the reporter's screenshot), `SoilMapOverlay.lua` (14), `SoilHarvesterPanel.lua` (14), `SoilSprayerInfoPanel.lua` (11), `SoilVariableRatePanel.lua` (5), `SoilSmartSensorPanel.lua` (4), `SoilMinimapLayer.lua` (2), `SoilTuningPanel.lua` (1), `SoilCropTuningPanel.lua` (1). Each needs a per-column width decided at the call site, which is why it is not a mechanical sweep.
- [x] Dry products haulable (SF #773, Arissani PARITY ruling): added `BULK` and `AUGERWAGON` category lines to `fillTypes.xml` covering UREA AN AMS MAP DAP POTASH POLIFOSKA GYPSUM COMPOST BIOSOLIDS CHICKEN_MANURE PELLETIZED_MANURE, matching the two transport categories vanilla FERTILIZER sits in. `isBulkType="true"` was already set on all twelve and is not the transport gate. Extension is additive, verified at `FillTypeManager.lua:145` and `:85`. Liquid half already satisfied via the existing LIQUIDFERTILIZER line. Reporter kylemeyer13 asked only for BULK; AUGERWAGON is included because parity with vanilla FERTILIZER is the ruling and vanilla FERTILIZER is in both. Built on development, PR open.
- [x] Organic market premium provenance (OM-213, SF half): the farm-level organic share accumulator for MarketDynamics' OrganicPremium modifier. `OrganicCertification:recordHarvest` folds each harvest pass into `organicFraction[farmId][fillTypeIndex]` (D1 blend, certified field = organic) from the combine's engine-passed `farmId`/`outputFillType`; `getFarmOrganicFraction` publishes the share; persists via soilData.xml and the StateLedger block. 20 assertions in om_213_organic_premium_test.lua (runs the real MarketEngine). Built on development, PR open.
- [x] Spray-paint streak re-fix (RSF-762): `SoilValueMaps:addPaintStrip` (additive parallelogram painter) + `paintBoomStrip` as a swept quad (prev painted line to current, no overlap, self-heals failed ticks, mass-conserving dose with the strip's own area as denominator). `markBoomCells` is now coverage-only. 34 assertions across the rewritten spray_paint_735_test.lua and rsf_762_spray_paint_strip_test.lua. Built on development, PR open.
- [x] Release gate (2026-08-02): the stable-vs-experimental lock. `ReleaseGate.lua` holds Arissani's certified lock set (CD-9 resistance, CD-10 hybrids, CD-12 tank mixes, ground material, spatial soil, Read the Dirt all LOCKED); `Settings:allowsExperimentalSystems()` is the explicit opt-in, orthogonal to difficulty. Experimental console commands (SoilResistance, SoilResistanceTest, SoilBlendCheck, SoilMaterialBench) refuse when locked, mirroring bypassLockedMsg(). New settings-panel row + SoilRelease status command + Release Gate dialog from the version dialog. **Sim wiring done same day:** the locked systems' entry points are gated - MaterialDown/Wetness/HayBet/YardLadder + spatialScouting only arm when their system is live (bridges gated too); SpatialPressures:run and the CD-9 resistance build / CD-10 hybrid onset / CD-12 blend handling only run when their system is live. Fail-open when settings unreadable. 68 assertions in release_gate_test.lua.
- [x] Variable pest and disease pressure (SF-19): outbreaks start in a patch and grow instead of one number per field. `SpatialPressures.lua` runs from the daily pass (server-only) after the field aggregate settles: ORIGIN picks weighted cells when pressure rises (disease: per-cell soil adapter incl. compaction as the 4th input; pest: edge-distance weight), SPREAD is seed-and-stamp single-hop-per-day with anti-saturation as an exclusion and a half-field ceiling guard. The key-not-invertible discipline holds (positions from live grid arithmetic via gx/gz, never decoding). Relief-weight coupling stance pinned: adapter reads the STORED OM while that feature is unbuilt. 22 assertions in variable_pressures_sf19_test.lua.
- [x] The kneel (SF-37): the active, precise reveal verb. Kneel (Shift+K) at a spot and the exact cell enters knowledge. `SpatialScouting:revealCellAt(connection, x, z, day)` writes one cell onto the walked mask, server-authoritative, LAW 4 (client key press = request carrying only x,z; farm from the requesting player's record via `playerSystem:getPlayerByConnection`). `SoilKneelEvent` carries the request. The field-level scout fee path stays byte-identical for spotless callers. 11 assertions in kneel_sf37_test.lua.
- [x] The handful read (SF-38): the frozen payload contract the Read the Dirt panel renders. `HandfulRead.assemble(ctx)` builds one payload from getters that all ship, per-clause grain + gates, zero writes. Material verdict takes the fill type from the caller (the layers are material-blind); diseaseKnown is cell-grain via the walked mask when a fresh cell exists. 35 assertions in handful_read_sf38_test.lua.
- [x] Spatial scouting walked mask (SF-26): on-foot walking reveals the trouble's pattern where you walked, per farm, fading after N in-game days. `SpatialScouting.lua` owns the per-farm mask (own home, LAW 2), samples server-side from the authoritative player list on foot only (LAW 1 + LAW 4), ages via Time Guard, persists via StateLedger with an own-XML fallback, delivers through NetworkSync (LAW 3: each entry carries {cell, walkDay, sampledTruth}), and composes at read time in SoilMapOverlay so the shared mirrors stay identical for every farm. Re-hide generation gate keeps pre-re-hide walks from resurrecting (acceptance 4). 38 assertions in spatial_scouting_spec_test.lua.
- [x] Ground-material family (SF-43 to SF-49, from #749): age layer + object ledger (SF-43), wetness + water record (SF-49), hay conversion + tedder hook (SF-44), straw swath (SF-45), bale condition ladder (SF-46). Merged to main in PR #767. Material birth wired at HookManager.lua:2749 and :3100. Reading surface (SF-48, Wizard) deferred by ruling.
- [x] CD-9 disease resistance family: F66 per-pass meter fix, CD-11 resistance data contract (four sync paths), CD-12 tank mix (28 blends), F68 durability dial (BUILD_RATE_NATURAL 0.25), saturated-save relief, CD-10 hybrid strains. Merged to main in PR #772. CD-11 readout (Wizard) still pending.
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
- [x] `sf_hud_pass_noproduct` (SoilHUD.lua:687) was defined in no language file at all, English included, so the HUD rendered the raw key name whenever a session pass had no known product. Added to all 27 files, each derived from that language's `sf_hud_pass_coverage` sibling minus the product parenthetical, so every file keeps its existing translated or `[EN]` state instead of gaining invented text. 2026-08-06.
- [ ] 90 strings still read `[EN]` in French and every one is `rf_pda_*` (Esc RF PDA chrome). Hold that ask until the Esc door work settles those surfaces, or the strings move under the translator.
- [ ] Worth a guard: nothing catches a `g_i18n:getText` key that exists in no translation file. The one above shipped and was only found by reading the source.

## Blocked / waiting on
- [!] getFieldInfo FieldSentry-state decision (waits on: audit answer).
- [!] ProStaff discount bridge (waits on: ProStaffCoOp handle confirmed + SF cost hook site scheduled).

## Esc doors + map buttons (2026-08-06)
- [x] Rotation Planner and Field Detail open from the Esc RF panel bottom bar (MENU_EXTRA_2 / MENU_ACTIVATE), selectedFieldId passed through (nil allowed). DONE in code, deployed.
- [x] Map sidebar report/treatment buttons restored via retained-page pattern (SoilPDAScreen._retainedDeepScreen + _ensureDeepPageInjectable). DONE in code, deployed.
- [~] In-game observation pending: confirm all three surfaces open with no Farm Tablet installed, and that the Esc rail still shows exactly one Realistic Farming tab.

## SF #764 Courseplay empty-tank (2026-08-07)
- [x] Root-caused via diagnostic trace: tank hits zero but fill type stays LIME (sub-threshold residual above the 0.00001 reset line); AI out-of-fill stop never fires. FIXED in code (complete the drain in appended onEndWorkAreaProcessing), built and deployed.
- [~] In-game verification pending: one failing run (T7.300 + Titan Teagle + lime) with the deployed zip should now stop and raise AutoDrive onCpEmpty.

## Esc panel buttons UI fixes (2026-08-07)
- [x] Bottom-bar buttons (Help, Rotation Planner, Field Detail) were disabled while the Esc menu is paused; fixed via showWhenPaused.
- [x] Cross-mod resolution: the door can be built by another mod's RfPdaMenuPage (MDM loads first), so callbacks now resolve Soil classes via the g_currentMission handoff instead of bare globals. Deployed and verified in-game.
- [x] Treatment button dropped after in-game pass: the map sidebar still opens the Treatment tab; the Esc panel keeps Back, Help, Rotation Planner, Field Detail.
- [x] Help button shows only on the Soil module; other modules show Back only (the Soil guide is Soil-specific).

## Module page dots always visible (2026-08-07)
- [x] The Esc RF module page dots were hidden while Worker Costs or Market Dynamics was active, so WC never read as the 3rd module. All four RfPdaMenuPage copies now keep them visible. Built, deployed, PR open.
