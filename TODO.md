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
- [x] Oilseed-radish nitrate by direct drill (issue #778): the crop-incorporation probe never ran on seeders, so terminating a cover crop with a direct drill (Väderstad Proceed V24) awarded only the flat DIRECT_DRILL residue and the nitrate HUD read "unchanged". Fixed by installing the #674 crop-biomass probe on `SowingMachine`, threading `_sfCropBiomass` into `onSowing`, and awarding the new `CROP_INCORPORATION.SOWING` profile (OM 0.4 / N 2.0 / P 0.4 / K 1.2) after the residue block, gated on `residueIncorporation` and biomass > 0. 20 assertions in crop_incorporation_sowing_778_test.lua. PR open.
- [ ] None open from the audit. Track new ones from GitHub issues here.

## Features / enhancements
- [x] SF-53 growth credit (SF-2M reward half, ratified 2026-08-12): `GrowthCredit.lua` (daily Time Guard bookkeeper at priority 97 + the period hand on the drained FINISHED_GROWTH_PERIOD delivery, bucketed executeSet writes on the engine's own fruit plane, engine-true targets from the crop growthMapping, skip-at-own-cutState, never into cut/withered/max). Wired at manager activation server-side; `ViabilityMask._readCredit` resolves through its socket. Ships LOCKED behind the growth_modulation release gate + SF-52 mask enable; unlock gated on SF-54's reading surface. 54 assertions in SF-53-growth_credit_bucket_spec_test.lua. Merged to development in PR #821.
- [x] SF-78 growth block (SF-2M hold half, ratified 2026-08-12): `GrowthBlock.lua`, capture at START_GROWTH_PERIOD (write-once across a bracket), restore at the drained FINISHED delivery through the same write machine as the family. R2 three-halves discriminator (fruit unchanged, not cut/withered, strictly above captured); target max(captured, current - cap); unconditional capture-clear at every drained delivery (cert assertion). No Time Guard registration. Inert behind the growth_modulation release gate + SF-52 mask enable. 24 assertions in SF-78-growth_block_restore_spec_test.lua. Merged to development in PR #822.
- [x] SF-77 topography cache (2026-08-12): `TopographyCache.lua`, the load-time terrain grid (adaptive 12-48 m cell, floor rounding, 180k cap, row-major) built once at map load with per-cell height, slope class, sink and distance-to-water; terrain edits mark cells stale via the terrainDeformationSyncer listener; stale answers are shaped defaults never nil; the static water-dist table persists via its own StateLedger module and delivers via NetworkSync. Consumers: SF-76 first, SCS-042 second. Neutral until a consumer wires in. 54 assertions in SF-77-topography_cache_spec_test.lua. Merged to development in PR #823.
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

## SF-18 establishment failure (2026-08-08)
- [x] `src/EstablishmentFailure.lua` built to the certified brief (full conformance): ESTABLISHING window (sowing -> first visible green, live-sampled close), daily threshold kill consuming SCS-018 positional `getMoisture(fieldId, x, z)` per zone cell, compaction-weighted + severity-scaled (Biological dial, neutral awaiting the spine), NO SIGNAL = NO THINNING, contiguous cells grouped into regions killed once each, verified in-mod substrate write (single DensityMapModifier polygon path, growth-state 0, weed/spray clear), base-game re-drill door.
- [x] Cadence: Time Guard `simulation` accrual at priority 95 (after moisture store 90, before stress/band refresh), SF day tracking fallback, frame-budgeted sweep pumped from update(); per-field daily wiring removed (it double-fired and made the feature inert).
- [x] `establishment_window_spec_test.lua` at 25 assertions (brief certs 23): window machine, threshold/compaction/severity, no-signal-no-thinning, kill-once, re-drill, live green close, positional per-cell kill with surviving cells keeping the window open, whole-stand close. Suite 2328/0 across 50 files; syntax + lint clean. Built and deployed.
- [~] In-game verification owed (the brief's in-game items): waterlogged seedbed yields bare ground following the water's contour (state-0 look), re-sow onto a killed region works, dedicated-server propagation of the density write, frame cost at a mass-sowing spring rollover.

## Water Record read on the manager (2026-08-10)
- [x] `SoilFertilityManager:getWaterDaysInLast(days, throughDay)` publishes SF-49's Water Record at the cross-mod boundary (`g_currentMission.soilFertilityManager`), delegating to the already-built `MaterialWetness:waterDaysInLast`. Returns `(count, known)`; nil on every unknown path (closed ground_material gate, missing or unarmed subsystem, throwing read, `known == 0`).
- [x] `water_record_delegate_test.lua` at 12 assertions. Suite 2516/0 across 53 files; syntax + lint clean.
- [~] Not ours to build: SeasonalCropStress's `getSkipRainHours` (SCS-037 round 2) goes live when it calls this delegate. In-game skip test is theirs.



## SF-19 visibility parity (2026-08-11)
- [x] `getFieldInfo(fieldId, x, z)` positional pest/disease/compaction reads from the value maps (tooltip parity); disease discovery gate holds on the positional read.
- [x] `HookManager.resolveCellPressure` reads pest/disease from the synced display maps first, then the cell, then the field scalar (see-and-spray client fidelity).
- [x] 21 new assertions across `sf19_tooltip_parity_test.lua` and `sf19_see_and_spray_repoint_test.lua`. Suite 2537/0 across 55 files.
- [~] In-game: scout reveal check on the PDA tooltip; MP client section-sprayer parity check.

## SF-23 spatial nutrients (2026-08-11)
- [x] Banded leach/pH/harvest distribution across cached moisture bands (`src/SpatialNutrients.lua`); conservation + floor rule pinned; one band = uniform.
- [x] Tier-0 texture via SCS soil type (loam fallback, F157 gap); spine Agronomy multiplier neutral 1.0; reciprocal getSoilValueAtWorld published on the manager.
- [x] 13 assertions in `sf23_spatial_nutrients_test.lua`. Suite 2550/0 across 56 files.
- [~] In-game: banded flush frame cost, hull edge behaviour, wet/dry nutrient picture. Maturity-asks: tier-1/2 texture, SCS consuming the reciprocal read.

## SF-21 neighbour crossing (2026-08-11)
- [x] Crossing pre-pass (completion gate LAW) + transient per-day snapshot; B2 pest arc weight recomposition; B3 conducive-gated disease boundary seeding with the protection fence; B4 constants.
- [x] `SpatialPressures:seedBoundaryOrigin` added (the reserved origin entry). Suite 2549/0 across 56 files.
- [~] In-game: bias over several days, clean-district parity, protection-window hold, no-moisture-mod, pre-pass frame cost.

## SF-27 NPC soil (2026-08-11)
- [x] NpcSoilBridge: designation read, phase-2 capability marker, fail-closed attribution; membership widened (owned OR NPC-managed); leave-path + reroll skip; treatment charge gated.
- [x] NPCFavor: isNPCManaged/getWorkingState/getNPCForFarmland published; flip uses a guarded real farm id (Lane B).
- [x] 24 assertions across npc_soil_gate + npc_soil_designation. Suite 2586/0 across 59 files.
- [~] In-game: NPC field survives daily pass/reroll/save-load; zero player money on NPC ops; buy-in inherits history; MP client paints NPC ground.
