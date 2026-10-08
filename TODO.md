# TODO: FS25_SoilFertilizer

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [x] Resolve Point 8 (ProStaff silent bridge): decided no bridge now; baseline v3 "already consumed" claim to be corrected by Claude(A) to planned-not-built.
- [ ] Confirm getFieldInfo should stay the sole companion read path; verify CropDisease and DairyCore call it (not `soilSystem.fields`) during their audits.
- [ ] Decide whether getFieldInfo exposes FieldSentry state or companions keep reading `g_currentMission.fieldSentry`.

## Bugs
- [x] Unplantable cells + crop vanishing from PDA (issues #878/#879): two defects in the SF-18 establishment kill. `killRegion` released the density-change ignore toggle inside the pcall that armed it, so a mid-write error left the growth system ignoring density changes for the whole session (freezing crop visibility and re-drilling); the release now runs unconditionally. A whole-stand kill reset the window but never cleared `field.sownCrop`, so SF kept reporting a planted/growing crop the vanilla PDA showed as absent; `_recordFullKill` clears the display bridge at every full-kill site, partial kills keep the crop. 10 assertions in `sf18_kill_state_spec_test.lua`. PR #892 merged. Copy-save in-game check still owed to fully close #878 (the fruit-plane/planter mechanism).
- [x] Starting Spring fresh-save all-zero fields (issue #880): the first `scanFields()` could run while `g_fieldManager.fields` was still empty (mission-start lifecycle mods), leaving `fieldData` empty so the post-load seeds painted nothing. Now a pending flag + bounded retry pump in `update()` re-scans until the fields appear (~20 s window), then replays zone-data + GRLE + value-map seeding. Client path untouched. 17 assertions in `deferred_scan_retry_spec_test.lua`. PR #891 merged.
- [x] Liquid tank multi-buy pricing (issue #882): liquid MAP was already correct; the audit caught copper_hydroxide and sulfur tables shifted one step up (roughly one extra tank at every qty >= 2) and mancozeb's qty-8 cell 800 under. All three now satisfy total = qty x unit price. Numeric-only edits in the `multipleItemPurchaseAmountConfiguration` tables. PR #890 merged.
- [x] 2026-07-26 bug sweep (54 total across ecosystem): SoilFertilizer bugs fixed and merged to main. See GitHub issues #748-#757 for individual tracking. All closed.
- [x] Oilseed-radish nitrate by direct drill (issue #778): the crop-incorporation probe never ran on seeders, so terminating a cover crop with a direct drill (Väderstad Proceed V24) awarded only the flat DIRECT_DRILL residue and the nitrate HUD read "unchanged". Fixed by installing the #674 crop-biomass probe on `SowingMachine`, threading `_sfCropBiomass` into `onSowing`, and awarding the new `CROP_INCORPORATION.SOWING` profile (OM 0.4 / N 2.0 / P 0.4 / K 1.2) after the residue block, gated on `residueIncorporation` and biomass > 0. 20 assertions in crop_incorporation_sowing_778_test.lua. **Merged to main in PR #781.**
- [x] Tractor side-tank NPK credit (issue #780): the credit died silently once the planter's liquid tank drained - `getActiveSprayType` returned nil, `getSprayerFillUnitIndex` fell back to a wrong-but-valid local unit (seed tank / second product tank), and `resolveSprayerFillTypeIndex` returned that local product, failing the nutrient-profile check. Fixed with an external-source guard (`wap.sprayVehicle ~= sprayer` -> wap.sprayFillType is authoritative) plus a recognized-product fallback to `wap.sprayFillType` with a debug log in the sprayer hook. 9 assertions in resolve_sprayer_filltype_780_test.lua. PR open.
- [ ] None open from the audit. Track new ones from GitHub issues here.

## Features / enhancements
- [x] F165 growth-credit store invalidation (2026-08-12, Claude(A) finding): a cell credited while bare (fruitIndex nil) is now a RESET, never a pass, and a cell that reads fruit UNKNOWN at the bell is invalidated in the stroke. Closes the fallow bank exploit (a season of bare-ground credit spent at once on a new crop), plus the gsFieldSetState and NPC-sim costumes. `GrowthCredit._guardCell` and `_strokeField`. SF-53 spec bar extended to 61 assertions. PR fix/F165 open.
- [x] SF-53 growth credit (SF-2M reward half, ratified 2026-08-12): `GrowthCredit.lua` (daily Time Guard bookkeeper at priority 97 + the period hand on the drained FINISHED_GROWTH_PERIOD delivery, bucketed executeSet writes on the engine's own fruit plane, engine-true targets from the crop growthMapping, skip-at-own-cutState, never into cut/withered/max). Wired at manager activation server-side; `ViabilityMask._readCredit` resolves through its socket. Ships LOCKED behind the growth_modulation release gate + SF-52 mask enable; unlock gated on SF-54's reading surface. 54 assertions in SF-53-growth_credit_bucket_spec_test.lua. Merged to development in PR #821.
- [x] SF-78 growth block (SF-2M hold half, ratified 2026-08-12): `GrowthBlock.lua`, capture at START_GROWTH_PERIOD (write-once across a bracket), restore at the drained FINISHED delivery through the same write machine as the family. R2 three-halves discriminator (fruit unchanged, not cut/withered, strictly above captured); target max(captured, current - cap); unconditional capture-clear at every drained delivery (cert assertion). No Time Guard registration. Inert behind the growth_modulation release gate + SF-52 mask enable. 24 assertions in SF-78-growth_block_restore_spec_test.lua. Merged to development in PR #822.
- [x] SF-77 topography cache (2026-08-12): `TopographyCache.lua`, the load-time terrain grid (adaptive 12-48 m cell, floor rounding, 180k cap, row-major) built once at map load with per-cell height, slope class, sink and distance-to-water; terrain edits mark cells stale via the terrainDeformationSyncer listener; stale answers are shaped defaults never nil; the static water-dist table persists via its own StateLedger module and delivers via NetworkSync. Consumers: SF-76 first, SCS-042 second. Neutral until a consumer wires in. 54 assertions in SF-77-topography_cache_spec_test.lua. Merged to development in PR #823.
- [x] SF-76 field genesis (2026-08-12): a new save's starting soil is seeded from terrain (height-relative, slope, sink proximity; from SF-77's cache when present, one direct sample when not). `_genesisDeviation` replaces the regional term in `_computeInitialSoil` only when `genesisActive`; same amplitude bounds, noise and clamps untouched. Manager arms genesis on a new save (no soilData.xml, server-only) with a deterministic savegame-directory-hash seed. Existing saves untouched (zero writes). 23 assertions in SF-76-field_genesis_spec_test.lua. PR feat/SF76 open.
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
- [x] 2026-08-12: the map sidebar report/treatment buttons removed again (the soil layer tab now draws only Disable Overlay and Help). The retained-page pattern stays for the Esc deep screens; the PDA deep page remains reachable from the Esc panel. In-game observation pending for the trimmed sidebar.
- [x] 2026-08-12: health summary re-anchored to stack under the sidebar column (was sitting well below the layer buttons), and a black per-layer info box added under it, shown when a layer is selected (12 new sf_map_layer_desc_* keys in all 27 translation files). In-game observation pending for both.

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

## RSF-836 swept quad boom line (2026-08-14)
- [x] True boom endpoints derived in the vehicle's own frame (components[1].node), main + fallback paths; paintBoomStrip consumes the line with a tip-swap guard; partial-width VWW exclusion inherited; cell stamping byte-identical.
- [x] rsf836_boom_line_test.lua at 11 assertions; suite 2886/0.
- [~] In-game: a wide boom on a diagonal pass, ground read after one pass (reporter antler22 offered the R4045 screenshots).

## Organic transition Time Guard normalization (2026-08-14)
- [x] TRANSITION_YEARS (2/3/5) resolved through Time Guard days-per-period at getTransitionDays; stale comments made true; state machine unchanged.
- [x] 11 assertions; suite 2897/0.
- [~] In-game: three in-game years at a 30-day month. Balance-pass values for the years table pending.

## Organic compost production (2026-08-14)
- [x] CompostManager: batch lifecycle, Time Guard day accrual + fallback, storage deposit, organic-safe flag, persistence, console.
- [x] 25 assertions; suite 2922/0.
- [~] In-game batch flow; FarmTablet organic-app batch display (read-only) pending the app's own work.

## Drilling-window advisory (2026-08-14)
- [x] Advisory verdict from the SCS rain outlook + moisture vs kill condition; three hedged strings in 26 languages; SF field-info line; silent without SCS.
- [x] 5 assertions; suite 2944/0.
- [~] In-game; FarmTablet mirror (hub read of the same surface).

## SF-55 traffic on wet ground (2026-08-14)
- [x] F111 closed: the driving compaction pass enumerates every server-side vehicle (wheel-on-ground gate, per-vehicle segment continuity) instead of `getPlayerVehicle()`, fixing compaction being dead on dedicated servers and host-only on listen servers.
- [x] Wetness-input substitution at both compaction call sites (driving + harvest): positional blend of SCS `getMoisture(fieldId)` with the rain-scalar fallback (confirm 2: max rule, rain as the calibrated floor). SoilCompactionModel scoring untouched.
- [x] `trafficDrag` layer: SoilValueMaps-registered, server-only, persisted, bounded 0.0-0.3 at the write, written on the driving segment walk when wet above threshold AND a standing crop occupies the cell, deduped once per cell per day on TimeGuard monotonicDay (never environment.currentDay). Second-writer fence holds; SF-55 never writes yieldEfficiency.
- [x] `TrafficDrag.lua` pure arithmetic module; `traffic_drag_test.lua` at 43 assertions. Suite 2962/0 across 73 files (om_213 needs the sibling MarketDynamics repo, absent in the temp clone). Bumped to 2.5.0.76.
- [~] Read-time composition with SF-14's yieldEfficiency (`effective = capturedEfficiency * (1 - trafficDrag)`) is a documented addendum owed on SF-14's staged brief at travel; until it lands, trafficDrag persists and composes with nothing.
- [~] In-game (owed): wet-field bruise at harvest, MP join confirms all actors compact, SCS present vs absent parity. Dials (magnitude 0.05, threshold 0.5, cap 0.3, min standing state 1) are AWAITING-SPINE neutral defaults.

## SF-14 zone yield (2026-08-14)
- [x] `src/ZoneYield.lua`: per-cell growth-time capture (rides the family's shared read, Time Guard simulation cadence, SF day-tracking fallback), the repurposed `yieldEfficiency` layer as captured truth (band 0.7-1.15, maxVal 115), and the freeze-supersession harvest read: area-weighted positional integral (SF-25's rule) of the captured layer across the header, computed fresh per pass, falling back to the untouched field-average `computeYieldModifier` when the spatial path cannot answer. SF-55 drag composition line applied from day one (nil drag = zero).
- [x] `ViabilityMask:getCellGrowthInfo` now reads the family's full input set (N/P/K + compaction + moisture) and carries the raw values; the `capturedEfficiency` socket reads through the manager's zone-yield subsystem.
- [x] The field-average display mirror/seed stand down from `yieldEfficiency` while the capture is live (the display-only stamp is retired).
- [x] 37 assertions in zone_yield_sf14_test.lua, including the calibration invariant: a uniform field's area-weighted read reconciles against computeYieldModifier output for the same inputs. Suite 2956/0 across 73 files; syntax + lint clean. Deployed 2.5.0.77.
- [~] In-game (owed): per-patch payout across a non-uniform header, uniform-field reconciliation vs the pre-family harvest, save/reload mid-harvest, harvest-read cost at full header width (named bench item, not asserted).

## SF-52 One Ground conformance provider (2026-09-09, draft PR into development)
- [x] Growth-input revision family at the SoilValueMaps mutator boundary (global / per-farmland / unscoped, session-local, never persisted); `_observeGrowthWrite` with EXECUTED/REFUSED outcomes at every public read-set mutator.
- [x] Manager delegates `getGrowthInputRevision()`, `getGrowthInputToken(fieldId)`, `getGrowthTruthGrainMetres()`; grain reports the loaded carrier's real metres per pixel.
- [x] Parcel-union geometry: `_getFarmlandPolygons` complete collection + pure helpers `pointInFarmlandUnion`, `polygonUnionFingerprint` (gaps never filled).
- [x] Repaired `getCellGrowthInfo` point contract: terrain domain, farmland existence, point-in-union, revision stability; SF-14 laundering socket closed (credit/capturedEfficiency held nil, sibling readers uncalled).
- [x] Ground-only plan + area-weighted summary + status getters: `getFieldGrowthSummary` additive shape, `getFieldGrowthSummaryStatus`, `getGrowthEligibleRegionPlan`.
- [x] Parcel-union enumeration, global ownership partition, atomic commit with pinned revisions and polygon-union fingerprint.
- [x] Establish/reload/teardown cadence; public `setEnabled` removed; Time Guard daily simulation accrual with host fallback (never `environment.currentDay`).
- [x] SF-52 bar 137/0; SF-53 61/0, SF-78 24/0, viability_mask 70/0, zone_yield 53/0. Only the pre-existing om_213 pair is red.
- [~] In-game (owed): SF52_RUNTIME_ACCEPTANCE harness (cannot run offline); per-frame cursor/time budget and execution-grain coarsening (3.5) and initial-generation timing (3.7) are runtime tuning deferred to the acceptance measurements.
- [~] SAMPLE_STEP_M / MAX_SAMPLES retained while SF-53 and SF-78 still snap to them; they leave when those siblings conform.

## SF-53 One Ground growth credit (2026-09-09, draft PR into development)
- [x] Two server-only bank layers in the current SoilValueMaps carrier (`growthCreditDays` packed byte: low seven bits bank days 0..84 + high bit appliedThisCrop; `growthCreditFruit` fruit 1..63); the exact 0..254 encode round-trips losslessly. Pair ops write/clear/post-read both halves and clear both on any one-sided result.
- [x] GrowthCredit rewritten off the SF-52 eligible-region plan: no more first-polygon 8 m / 600-point lattice or ephemeral per-field Lua bank. Daily walk iterates each farmland's complete current plan at the execution grain, reads SF-52 point bands fresh, binds fruit identity before the first increment, and a changed crop clears the old pair.
- [x] Evidence-bounded catch-up: every crossed day only when stored farmland/unscoped revision, polygon fingerprint and settings fingerprint all match today; any change awards at most the observed day. Restored banks stay PENDING_VALIDATION; no retroactive multi-day award crosses reload. Time Guard registration literal-true only; host monotonic-day fallback.
- [x] Shipped Option-Scaling threshold (dial agronomy, base/neutral 2, clamp 1..3) via vendored readProfile/resolve; absent or switched-off profile is neutral. Old `.value(dial)` stub retired.
- [x] Manager-owned single family growth dispatch (one START + one FINISHED subscription routed to conformed members); GrowthCredit no longer self-subscribes. Ordered brackets with immutable target period; FINISHED closes on every path, only drained/stable/gate-live/unchanged-generation spends.
- [x] Post-state-verified spend: target from the bracket's immutable mapping, bucket by (fruit, source, target), 4-connected rings at the plan grain, one filtered executeSet per bucket; after the call only cells re-read at exactly the target under the same fruit clear bank-day bits and set appliedThisCrop. Failures retain credit.
- [x] Small metadata (schema, fruit-roster, resolution, truth grain, per-farmland geometry/last-day/settings) rides `soilData.growthCredit` XML + StateLedger mirror; no per-cell list, no second save service. Dense truth is the two GRLE files.
- [x] `readCreditAt` / `getGrowthSurfaceWitness` return server credit + provenance witness; client/stale/partial/mismatched return nil. Delete unregisters the Time Guard accrual and drops accessors.
- [x] SF-53 bar 139/0 (Groups A-I; Group A re-pointed to shipped surfaces); siblings green (SF-52 137/0, SF-78 24/0, viability 70/0, zone_yield 53/0); only om_213 red.
- [~] In-game (owed): SF53_RUNTIME_ACCEPTANCE harness (cannot run offline); native fruit-plane filter/ring/multi-write and post-state behavior, paired-file interruption + GRLE recovery, dedicated-server START/FINISHED and client engine sync, real bank bytes/save duration/frame cost.

## SF-78 One Ground growth hold (2026-09-10, draft PR #931 into development)

- [x] `GrowthBlock.lua` conformance rewrite over the SF-52 plan; seven unsafe behaviors retired (8m/600 lattice, ephemeral Lua capture, arbitrary restore cap, `isLive` gate-close wedge, subscription leak, no-ring/no-postread write, cached resolver socket).
- [x] Paired carrier layers `growthBlockState` + `growthBlockFruit` (ACTIVE bit6/HELD bit7) in SoilValueMaps; one logical pair, no fifth map.
- [x] Manager family dispatch routes START/FINISHED to GrowthBlock; no independent subscription; no Time Guard (engine bracket is the clock).
- [x] Write-once ACTIVE capture at first START; later START never recaptures, increments stable-receipt transition count; global change stales the batch.
- [x] Drained FINISHED restores stable receipts (bucket by fruit/source/target, rings at plan grain, one filtered executeSet, post-state re-read), HELD only verified cells, then clears active authority unconditionally (cert assertion).
- [x] Target `max(captured, current - steps*transitionCount)`, never below captured; steps via `OptionScalingResolver` (agronomy base1 clamp1..2), neutral 1.
- [x] Metadata rides `soilData.growthBlock` XML + StateLedger mirror; dense truth in the two GRLE files. `getGrowthSurfaceWitness` + `isCapturedAtFirstStart` surfaces.
- [x] SF-78 bar 109/0 (Groups A-I; Group A shipped-surface re-point); full suite 3505 passed, only om_213 red; syntax + lint clean.
- [~] In-game (owed): SF78_RUNTIME_ACCEPTANCE harness (cannot run offline); native write + post-state, paired-file interruption + GRLE recovery, dedicated-server sequence + client sync, real bytes/duration/frame cost.

## SF-79 sprayed-area lime and chemical pH (2026-09-10, draft PR #933 into development)

- [x] `src/PositionalPH.lua`: positional pH writer `_applyPHFootprint` (DELTA/SET/NORMALIZE x POINT/STRIP/POLYGON/FIELD); the pH map is the authority, the field number is a derived report; saturation cohorts before the interior add (240+10 -> 250).
- [x] Derived `_phReport`/`_ensurePHReport` + preservation-first migration + domain-keyed sub-step remainders; metadata on `soilData` XML + StateLedger.
- [x] Every pH writer routed (application, daily/meadow normalize, rain, burn, scorch, admin); pH removed from the scalar replay and the SpatialNutrients second paint.
- [x] `getFieldInfo` pH read contract (pHStatus/pHGrainMetres/pHRevision/pHLastKnown; nil when unavailable) + ~20-consumer nil sweep; `needsFertilizationKnown`.
- [x] `updatePHWorkAuto` pH-aware AUTO rate applied once before the multiplier.
- [x] Network: `pHReportValid` beside the pH report on full/batch/update + NetworkSync SCALARS; FULL/PATCH chunk transport header + multi-part assembler.
- [x] SF-79 bar 114/0 (Groups A-J; Group A shipped-surface re-point); full suite 3619 passed, only om_213 red; syntax + lint clean.
- [~] In-game (owed): SF79_RUNTIME_ACCEPTANCE harness (cannot run offline); native executeGet sum/count, union masks, 8 KiB payload framing, save interruption + GRLE recovery, dedi/client sync.

## SF-14 One Ground zone yield (2026-09-10, draft PR #932 into development)

- [x] `ZoneYield.lua` conformance rewrite over the SF-52 plan; four source defects retired (first-field/one-fruit identity, private 8m/600 ruler, incomplete axis-aligned drag box, legacy scalar readiness/freeze).
- [x] Plan consumption + polygon-fruit receipts `(farmlandId, sourcePolygonFingerprint, fruitTypeIndex)` with PENDING/READY/FROZEN_SPATIAL/FROZEN_FALLBACK; contract fallback map separate.
- [x] Manager family dispatch routes START/FINISHED to ZoneYield; no independent subscription; bounded job pump from the manager update path.
- [x] Capture reads N/P/K once, `clamp(baseline + (localRaw-baseline)*variationScale, 0.70, 1.15)`, writes the provider footprint and post-reads; a failed read/write/post-read fails the farmland job; drift cancels and leaves PENDING.
- [x] Descriptor/route admission + two-part regrowth thaw + OptionScaling variation (agronomy base1 clamp0.5..1.5), neutral 1.
- [x] Native fruit-filtered harvest read + rotated <=256 drag lattice; four Cutter surfaces retained; sowing door clears matching receipts.
- [x] Metadata rides `soilData.zoneYield` XML + StateLedger mirror; dense truth in the yieldEfficiency GRLE. `getGrowthSurfaceWitness` surface.
- [x] SF-14 bar 155/0 (Groups A-I; Group A shipped-surface re-point); full suite 3607 passed, only om_213 red; syntax + lint clean.
- [~] In-game (owed): SF14_RUNTIME_ACCEPTANCE harness (cannot run offline); native writes + post-read, polygon clipping, save interruption + GRLE recovery, dedicated-server sequence + client sync, real bytes/duration/frame cost.

## Big bag labels (2026-10-03, issue #1087, MAINTENANCE 212)

- [x] DAP: back to its own print (`dap/bigBag_dap.i3d` loads `bigBag_dap_diffuse.png`).
- [x] Polifoska: its own i3d, shapes copy and print in `objects/bigBag/polifoska/`; `polifoska/bigBag_polifoska.xml` loads that i3d.
- [x] AN: `an/bigBag_an.i3d` loads `bigBag_an_diffuse.dds`; the urea copy `an/bigBag_an_diffuse.png` is deleted.
- [x] Bar: `node tools/test/bigbag-labels-check.mjs` (16 rows; the same bar against development ebe20f77 fails 7 by assertion, naming the AN+UREA and DAP+POLIFOSKA shared labels).
- [~] In game (owed): the shop preview and a placed bag for DAP, Polifoska and AN each show their own label; no texture or i3d warning for objects/bigBag in log.txt; the same on a dedicated-server client.

## SF-73 section 7 target surface (2026-10-03: W1a #1084, W1b #1088, #1089, #1090)

- [x] W1a: the rate panel's target block (`src/ui/SoilHUD.lua`), 46 keys in 27 locales; bar `SF-73-W1a-hud_target_block_spec_test.lua`.
- [x] W1b: the PDA target card (`src/ui/RfPdaSoilPanel.lua`), the per-field last-pass memory (`src/target/TargetApplication.lua`), and the one reason order the HUD and the PDA share (`src/target/TargetNutrientCore.lua`); bar `SF-73-W1b-pda_target_card_spec_test.lua`.
- [x] MAINTENANCE 211: the witness refusal names its field; bar `MAINT-211-refusal_fieldid_spec_test.lua`.
- [x] The PDA last pause: the per-field pause memory and its guarded read; bar `SF-73-pda_last_pause_spec_test.lua`.
- [~] In game (owed): TESTING rows 393, 405, 406 and 407, then Sasha's unlock of sf73_target.

## RSF-F190 own-farm barn-warning privacy (2026-10-04, Unified A3)

- [x] `src/DogEarlyWarning.lua`: the presentation context, the private barn bindings, the barn notifier and the pure getter; `src/main.lua` releases the dog at unload.
- [x] Bars: `RSF-F190-barn_privacy_spec_test.lua` (two farms, main.lua's own dog statements); the F190 reader and F192 l10n benches given a farm-1 player and doghouse; battery `tools/test/mutate_f190_privacy.py`.
- [~] In game (owed): two farms with a doghouse each and only farm 2's barn sick, on solo, listen host, pure client and dedicated; a spectator; a farm switch before a scan and during a toast; dog loss and regain; a barn transferred, removed and replaced; the provider absent; save and rejoin.

## 2026-10-04 (Fred): the shared RF Esc door (Wizard, #1094)

- [x] The four shared door files at the suite's STOCK page set, byte-same in all ten door mods; StockGuard's STOCK page chrome inert without StockGuard; the herd-advisory panel hidden.
- [~] In game (owed): TESTING row 419.

## 2026-10-05 (Fred): the Esc side panel's info box (Wizard, #1097)

- [x] The side info boxes start clear of the selected tab; text bodies 352 and 348 px wide, so line length and the right edge are unchanged; byte-same in all ten door mods.
- [~] In game (owed): TESTING row 447.

## SG2-5e-soil: the partial round bale's pre-pad account (2026-10-05, SG-2 :475, Soil's half)

- [x] `src/ground/BalerCollection.lua`: `BC.prePadAccount`, captured in `aroundUnloading` before the pad; `aroundFinish`'s pad branch prefers it. The `:665` comment no longer says only a square chamber's record holds an account.
- [x] Bars: `SG2-5e-soil_round_pad_account_spec_test.lua` (a plain round baler from `BALER_MODEL.newRound`, unloaded through its own wrapped `setIsUnloadingBale`); battery `tools/test/mutate_sg25es.py`.
- [ ] StockGuard 5e-b frames the round chamber (Part 1), then 5e-d keeps the forming stock pending until dropBale.
- [~] In game (owed, once 5e-b is in): a partial round bale with StockGuard and Soil both installed carries a wetness, not "unknown".

## CD-15 step 1b: the save participant (2026-10-05)

- [x] `src/disease/CD15Save.lua` (new): header, payload, completion, restore decision; `src/disease/CD15Model.lua`: RESTORING, FIRST_ACTIVATION, QUARANTINED, import and export of the day work, `fail`; header seams in `src/SoilFertilityManager.lua` and `src/integrations/SoilStateLedgerBridge.lua`; install and teardown in `src/main.lua`; the two pcall seams in `src/SoilFertilitySystem.lua`.
- [x] Bars: `CD15-1b-save_participant_spec_test.lua` (E entry point, B, Q, D, L, C, F, O, W, J); group M in `CD15-1a-local_grid_spec_test.lua` (the seams); battery `tools/test/mutate_cd15_1b.py`.
- [x] Step 1c: discovery, classification, the whole-cell witness and admission (answering UNKNOWN_OCCURRENCE until a supported profile exists); it resumes the discovery cursor this payload already carries (2026-10-06, below).
- [ ] Step 2's and 3's writers bring the re-entry invalidation of an open attempt (brief :91).
- [~] In game (owed): a save and reload with Soil alone and with StockGuard; a save interrupted by quitting; a hand-deleted soilDisease.xml loads quarantined.

## 2026-10-06 (Fred): modDesc.xml encoding repair (MAINTENANCE row 221)

- [x] 43 garbled title and description lines decoded back to the text already decided; nothing else touched.
- [~] In game (owed): TESTING row 483.

## CD-15 step 1c: discovery and admission (2026-10-06)

- [x] `src/disease/CD15Admission.lua` (new): candidates from the cultivated polygons and the kept rows, the vocabulary classification, the whole-cell witness over every plane and overlapping pixel, admission, membership, the profile table (empty: UNKNOWN_OCCURRENCE until a profile is recorded); `src/disease/CD15Model.lua`: discovery in the update behind the hold, sharing the 256 bound, the cell's wetness passed to the day; `src/disease/CD15Day.lua`: MINOR 2's onset wetness and MINOR 3's membership path for spread; `src/main.lua`: one source line.
- [x] Bars: `CD15-1c-admission_spec_test.lua` (E entry point, H, C, P, R, A, B, G, M); battery `tools/test/mutate_cd15_1c.py`.
- [ ] A supported native profile (TESTING rows 32 and 33's numbers) before any cell is admitted in play.
- [ ] Step 2's native writers call `CD15Admission.invalidate` on a native transition.

## MAINTENANCE row 229: switched-off sections do not stamp (2026-10-06)

- [x] `HookManager:cellsToStamp` (new) filters the cell sweep at the four `markBoomCells` call sites; `_switchedOffGround` and `HookManager.sectionLateralGround` (new) give each section's lateral ground from #sectionIndex work areas or tips, off from the preserver's saved state; a spraying section whose ground is unknown stops the filter.
- [x] Bar: `MAINT-229-section_stamp_spec_test.lua` on `MAINT-229-section_boom_world.lua` (A boom-wide work area and a centre section, X the same boom driving along world X both ways, B Soil's own suppression, W per-section work areas, S lime, M multi-tank); battery `tools/test/mutate_maint229_section_stamp.py`.
- [~] In game (owed): TESTING row 490.
- [ ] MAINTENANCE row 230: the dose line (getBoomLineEndpoints) has the same span holes; not queued.

## MAINTENANCE row 232: each section reads the ground under itself (2026-10-06)

- [x] `HookManager:sectionSamplePoints` (new, cached per tick): points across each section's own lateral ground on its boom line, from `HookManager.sectionLateralExtents` (split out of #1104's `sectionLateralGround`, which is unchanged). Smart Sensor and Variable Rate read the centre point; See & Spray reads every point (skip only when all readable points say skip, the highest graduated share).
- [x] Bar: `MAINT-232-section_sample_spec_test.lua` on `MAINT-232-section_sample_world.lua` (W weeds, P pest cells and the graduated rate, S Smart Sensor, V Variable Rate, C the points following the sprayer); battery `tools/test/mutate_maint232_section_sample.py`.
- [~] In game (owed): TESTING row 492.

## MAINTENANCE row 234: overlap prevention's finer record (2026-10-06)

- [x] `ZONE.OVERLAP_CELL_SIZE` (2 m); `HookManager.overlapCellKey`, `isOverlapCellSprayedEarlier`, `getBoomOverlapPositions` (the record's cells laid along the boom in the sprayer's own frame, at any heading), `_switchedOffGrounds` (shared with `cellsToStamp`) and `markOverlapRecord` (new); `SoilFertilitySystem:markOverlapCells` (new) beside every `markBoomCells` call; both readers on the record at the tip; the record cleared at the five session-cell resets.
- [x] Bar: `MAINT-234-overlap_record_spec_test.lua` on `MAINT-234-overlap_record_world.lua` (N two rows with 2 m of overlap and the unchanged 10 m record, A two rows and a lane end at 45 degrees, W switched-off sections, O another vehicle's pass, R the clears); battery `tools/test/mutate_maint234_overlap_record.py`. `overlap_own_pass_grace_test.lua` and `SF-73-target_entry_point_test.lua` write their other-vehicle passes to the record too.
- [~] In game (owed): TESTING row 493.

## MAINTENANCE row 244: constants on the manager (2026-10-07)

- [x] `src/main.lua` load: `sfm.SoilConstants = SoilConstants` beside `mission.soilFertilityManager`.
- [x] Bar: `MAINT-244-constants_on_manager_spec_test.lua` (E main.lua's own site in Soil's mod environment, FarmTablet's reads verbatim in its own); battery `tools/test/mutate_maint244.py`, 2 of 2.
- [~] In game (owed): TESTING row 506.

## MAINTENANCE row 251: Time Guard skew guard (2026-10-08)

- [x] `src/EstablishmentFailure.lua`, `src/GrowthCredit.lua`, `src/ViabilityMask.lua` `registerDailyAccrual`: the class list read through `tg.scheduler.FLOW_CLASSES`, nil-safe. SF-53's fixture models `scheduler`.
- [x] Bar: `MAINT-251-timeguard_skew_guard_entry_spec_test.lua` (production's activateSoilSystem, Time Guard on the mission only, v1.0.0.0 and current shapes); battery `tools/test/mutate_maint251.py`, 9 of 9.
- [~] In game (owed): TESTING row 516.
