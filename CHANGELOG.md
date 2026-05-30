# Changelog

All notable changes to FS25_SoilFertilizer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [2.2.5.0]

### Fixed
- Fixed weed pressure bar oscillating after partial herbicide spray (same-day sticky fix)
- Fixed Weeds/Pests/Disease % values misaligned in HUD — values are now left-aligned after their bar, not offset by one row
- Fixed version dialog not appearing when mod was previously disabled
- Fixed Precision Farming detection incorrectly triggering for users with PF installed but disabled in mod manager
- Fixed startup crash in fill type category lookup
- Fixed version dialog suppressed by crashes during mod initialization

### Translations
- **French (fr)** — Community translation update

---

## [2.2.4.1]

### Fixed
- Fixed Weeds/Pests/Disease HUD bars rendering one row above their row labels (visual alignment regression from 2.2.4.0)

---

## [2.2.4.0]

### Fixed
- Fixed N and K starting at 90%+ on new saves (nutrient defaults now correctly initialize at N=50, P=33, K=38)
- Fixed Pass% capping at ~50% after a full-field spray
- Fixed Partial Width mode crediting inactive boom sections toward coverage
- Fixed variable rate display oscillating when using MAP/P-type fertilizers
- Fixed liquid lime draining the entire tank instantly
- Fixed herbicide session coverage resetting between spray sessions
- Fixed LIQUIDLIME remapping to the correct spray type
- Fixed herbicide weed browning and protection window

### Translations
- **Danish (da)** — Translation update

---

## [2.2.3.6]

### Fixed
- Fixed multi-purchase pricing: buying 2+ big bags charged double the correct price
- Fixed spray rates for herbicide/insecticide/fungicide: 1.5 L/ha → 100 L/ha realistic carrier rate
- Fixed AN 34.5 Dry not loadable into spreaders on some setups
- Fixed dedicated server fill type registration failure (retry mechanism for late-loading fill types)
- Fixed issue where only the mid section of the boom would spray


---

## [2.2.3.5]

### Fixed
- Added a detection mechanism that will disable our mod if Precision Farming is detected, to prevent conflicts and data corruption
- Fixed a issue where our injection failed on load due to loading order issues

---

## [2.2.3.4] - Pre Built (beta)

### Fixed
- **HUD layout mode stuck on foot** ([reported by Tomi89](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues)) — When toggling HUD layout/drag mode with a custom keybind while on foot (outside a vehicle), the second press (close) did not release the mouse cursor or restore camera rotation. The cursor remained locked on screen, preventing the player from looking around. Root cause: `SoilHUD:update()` was calling `g_inputBinding:setShowMouseCursor(true, true)` every frame while in edit mode, creating a persistent forced-cursor state that the single `setShowMouseCursor(false)` call in `exitEditMode()` could not clear. The per-frame cursor call was removed; cursor management is now handled exclusively by `enterEditMode()` / `exitEditMode()` state transitions (matching the FS25 reference pattern). Works correctly in vehicles because vehicle mount/dismount resets all input state as a side effect.

---

## [2.2.3.3] - Not yet released

### Added
- **Settings panel scrolling** — Category pages now scroll when content exceeds the visible area; a proportional scrollbar with up/down arrows appears automatically when needed.

### Fixed
- **POLIFOSKA fully wired** — Drain rate, spreader effects, visual texture, PF/THPF recognition, and refill pricing now all work correctly (6-20-30 compound, 250 kg/ha calibrated rate, 1.35 $/L refill price).

### Translations
- **French (fr)** — Full native translation update by Seb/Squall39, covering all new strings: Disease Climate, Smart Systems, See & Spray, Variable Rate, HUD Layout, Big Bag names, and more.

---

## [2.2.3.2] - 2026-05-24

### Fixed
- **Collapsed panel stacking overlap** — When a smart system panel (Smart Sensor, See & Spray, or Variable Rate) was collapsed, panels below it rendered at the wrong position, causing overlap. Root cause: all three panels computed their stacked Y position using `fullPanelH` before evaluating the collapsed state. Each panel now determines `panelH` (actual rendered height) before calculating `stackedY`, so downstream panels anchor to the correct collapsed size.
- **System panels stay visible when HUD is hidden** — Pressing H to toggle the main Soil Monitor HUD off did not hide the Smart Sensor, See & Spray, or Variable Rate overlay panels. All three now check `hud.visible` in their `draw()` functions and return early when the HUD is hidden.
- **POLIFOSKA not loading into spreaders** — POLIFOSKA was missing from the hardcoded fill-type allow-list in both `installFillUnitHookEarly` and `installFillUnitHook`. Added to `solidNames` alongside UREA, DAP, etc. Also added a category-based fallback using `getFillTypesByCategoryNames` so any fill type registered in the `fertilizer` or `liquidFertilizer` category is automatically accepted — prevents the same omission from recurring for future fill types.

---

## [2.2.3.1] - 2026-05-23

### Fixed
- **Smart Sensor panel drag broken** — `SoilFertilityManager` stored the Smart Sensor panel as `self.sensorPanel` but all callers (SoilHUD, SeeAndSpray, VariableRate) referenced `sfm.smartSensorPanel`. The field was always nil; the panel was never draggable. Renamed to `smartSensorPanel` consistently.
- **Admin page nav buttons cut off** — The Admin settings page placed its Actions section (Save, Reset, Smart Systems, Vehicle Tools nav buttons) at the bottom of a content area that exceeded the visible panel height. Moved the Actions section to the top so navigation buttons are always visible.
- **Disabled system panels leaving layout gaps** — When a system panel was disabled, it returned early from `draw()` without resetting `lastPanelH`, leaving a stale height value that caused the next enabled panel to leave a gap. All three panels now reset `self.lastPanelH = 0` at the very start of `draw()`.
- **System panels not visible in Shift+H edit mode without a sprayer** — In edit + independent-panel mode, panels returned early when no sprayer was active, making them invisible and un-draggable without being in a vehicle. Now call `drawPanel()` for hit-testing even with `sprayer = nil`.
- **System panels visible behind the Shift+O settings panel** — `g_gui:getIsGuiVisible()` does not detect SF's custom settings panel. Added an explicit check for `sfm.settingsPanel.isVisible`.

### Changed
- Guide dialog, README, and mod description updated to document all three Smart Precision Systems and the Free Panel Layout feature.

---

## [2.2.3.0] - 2026-05-23

### Added
- **Smart Sensor (System 1)** — Blocks individual sprayer boom sections when the detected pest, disease, or nutrient need for that section's soil cell falls below a configurable threshold. Reduces product waste on areas that do not need treatment. Toggle with Alt+1/2/3 from inside a VWW-equipped sprayer.
- **See & Spray (System 2)** — In-vehicle HUD overlay displaying live per-cell pest, disease, and weed pressure readings with red/gray dot indicators showing which sections the Smart Sensor is actively suppressing. Toggle with Alt+4/5/6.
- **Variable Rate Application (System 3)** — Automatically adjusts per-section boom application rate from the current soil nutrient deficit. A bar-chart overlay shows the live rate multiplier for each boom section. Toggle with Alt+7.
- **Free Panel Layout** — Independent positioning and collapsing for all three smart system panels. Enable in Settings → Display → HUD Layout. Enter Shift+H edit mode to drag each panel; press the **[−]** button in any panel's title bar to collapse it to just the title bar. Positions and collapse state saved to `hud.xml`.
- **Admin: Smart Systems page** — Dedicated settings page under Admin → Smart Systems with individual enable/disable toggles for each system (`smartSensorEnabled`, `seeAndSprayEnabled`, `variableRateEnabled`).
- **Move & Resize Panels button** in Display & HUD settings — closes the settings panel and enters HUD drag/resize mode directly.
- All 26 languages updated with Smart Systems, See & Spray, and Variable Rate keys.

### Fixed
- **PESTICIDE fill type reducing weed pressure instead of pest pressure** — The vanilla FS25 / PF PESTICIDE fill type was listed in `HERBICIDE_TYPES`. Every insecticide application silently routed to weed-pressure reduction, leaving pest pressure permanently at 0% despite full-tank consumption. Moved PESTICIDE to `INSECTICIDE_TYPES` at 1.0 effectiveness.
- **SprayerHook usage=0 debug spam** — Throttled to at most once per 3 seconds per vehicle; eliminated 60+ lines/second headland-turn spam in debug mode.

---

## [2.2.2.5] - 2026-05-22

### Fixed
- **Version dialog cleanup** — Removed stale wording and tightened layout for the startup changelog dialog.
- **Version dialog deferred 3 s after mission start** — In some savegame configurations the dialog appeared before the GUI was fully ready, causing a visual race condition. Now deferred by 3 seconds after `loadMission00Finished`.

---

## [2.2.2.4] - 2026-05-22

### Added
- **5-tab Field Guide dialog** — In-game reference guide (accessible via the Guide button on the version dialog or from the settings panel) with tabs covering Soil Nutrients, Crop Health, Fertilizer Types, Smart Systems, and FAQ.
- **Color-coded HUD tick marks** — Nutrient bar tick marks now reflect status tier (green/amber/red) matching the bar color, making threshold boundaries immediately readable at a glance.

### Fixed
- **Guide dialog text clipping** — Guide content was overflowing the dialog box on non-default font scales. Dedicated wide text profiles added; box height expanded.
- **Version dialog showing on every boot** — Changed behavior so the dialog shows on every load until the player explicitly clicks "Don't Show Again", rather than once per session.
- **Guide button added to version dialog** — Clicking it closes the version dialog and opens the Field Guide directly.
- **Spray rate panel clears in one pass** — The application rate display no longer requires two consecutive passes to reset after switching products.
- **Yield threshold aligned with GOOD status** — The yield-efficiency display threshold was inconsistent with the HUD's "Good" status boundary. Aligned to the same constant.
- **Version dialog auto-saves** — Closing the version dialog now persists the last-seen version immediately without requiring a manual save.

---

## [2.2.2.3] - 2026-05-21

### Changed
- **All keybindings unbound by default** — Cross-mod conflicts (Shift+H, Shift+M, Shift+O, F7) caused hard-locks when multiple mods shared defaults. All SF input actions now ship unbound; players assign keys once in Controls → Mods.

### Fixed
- **Soil Cell Map was bound to Shift+S** — Shift+S is the vanilla sprint-backwards combo. Binding any dialog to it caused the popup to open on every backward sprint stop. Reverted and left unbound.
- **SoilMapCellDialog auto-loads player position on open** — The cell-detail dialog is no longer blank when first opened; it immediately queries the cell at the player or vehicle position.

---

## [2.2.2.1] - 2026-05-20

### Fixed
- **Section control overlap with Precision Farming** — Switched `installDensityMapSprayHook` from `prependedFunction` to `appendedFunction` on `Sprayer.onStartWorkAreaProcessing`. The original function sets `wap.sprayType` internally; a prepended hook ran before that assignment, so the C++ layer always received an unrecognised custom fill type index, returned `changedArea=0`, and PF's inside-field overlap detection had no valid signal — boom sections stayed open on fully-fertilised soil while moving forward.
- **AN (Ammonium Nitrate) fill type not recognised** — `AN` was missing from `solidNames` in all four hook functions (`registerCustomSprayTypes`, `installEffectTypeHook`, `installSprayTypeEffectsHook`, `installDensityMapSprayHook`). Spray effects, density map writes, and soil tracking were all silently skipped for AN applications.

---

## [2.2.1.0] - 2026-05-19

### Added
- **Polifoska 6-20-30 compound NPK fertilizer** (Issue [#404](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/404)) — new dry bulk fill type with calibrated nutrient profile (+4N +21P +50K ppm/ha @ 250 kg/ha). Available as a 1 000 L big bag via the in-game shop. Uses the standard fertilizer spreader spray type. All 26 language files include English display names; translators can localise `sf_polifoska_title`, `sf_bigBag_polifoska_name`, and `sf_bigBag_polifoska_function`.
- **Yield efficiency HUD indicator** — shows the current field's yield modifier as a percentage with colour-coded status (green ≥ 90 %, amber 70–89 %, red < 70 %).
- **Treatment rates panel on HUD** — displays the recommended application rate for the active fill type alongside the current rate multiplier.
- **Multiplayer daily broadcast** — server now broadcasts a daily nutrient-state delta to all connected clients so late joiners see up-to-date field data without a full sync.
- **Big Bag Compost 10 000 L variant** — large-volume compost big bag for high-throughput organic matter applications.
- **Hungarian translation** — full native translation by community contributor @MathiasHun (all 644 keys).

### Fixed
- **`isFertilizerApplicator` permanently marks implements as non-applicators on session load** (Issue [#406](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/406)) — the function cached `false` when called before a vehicle's specializations were fully initialised (early mission load). Implements that were actually sprayers were never re-evaluated and the rate-control HUD panel never appeared for them. Fixed by only caching `true` results; `false` is re-evaluated on each call until the spec is loaded.
- **Harvest nutrient depletion misses field on large combines** (Issue [#401](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/401)) — `combineSelf.rootNode` (mid-rear body pivot) can sit outside the field polygon when the header extends far forward. Both the harvest hook (`Combine.addCutterArea`) and the yield modifier hook (`FillUnit.addFillUnitFillLevel`) now fall back to the attached cutter/header rootNode and then to each work area start point when the combine rootNode fails to resolve to a field. Mirrors the pattern already in the sprayer hook.
- **Weed pressure formula inverted** — `weedFactor` of 0 means clean field and 1 means maximum weeds (matching the FS25 `FieldState` default), but the formula was applying `(1 - weedFactor)` as the penalty multiplier, meaning a clean field received the full weed penalty and a weedy field received no penalty. Corrected to apply the penalty when `weedFactor > 0`.
- **Weed density model replaced with native FS25 read** — the custom weed-accumulation model diverged from the engine's density map state, causing phantom weed penalties on freshly-ploughed or bare fields. Now reads `FieldState.weedFactor` directly from the FS25 density map each game day.
- **Weeds 100 % on bare / unfarmed fields** — when no field state was available the weed factor defaulted to 1.0 (maximum weeds), penalising fields that had never been farmed. Now defaults to 0.0 (no weeds) when field state is unavailable.
- **Zone cell K average out of sync with field average** — K was being written to zone cells using an incorrect scale factor, making per-cell K values drift from the field-level average displayed in the HUD.
- **`calculateHeight` omits N row when pfCompatibilityMode is active** — the height-calculation path guarded by `pfCompatibilityMode` was skipping the N bar, causing a layout gap in the HUD nutrient stack.
- **Duplicate yield row in HUD** — the yield efficiency line was registered twice in the HUD layout, causing a blank duplicate row.
- **pfCompatibilityMode now correctly gates PF integration at runtime** — toggling the setting previously had no effect until the next game load. The PF bridge now checks the flag on each applicable event.
- **N* label removed; pfCompat setting hidden when PF is absent** — the asterisk label was confusing players not using Precision Farming; the compatibility-mode setting is now hidden in the UI when the PF mod is not loaded.
- **Multiplayer overlay blank for clients** — soil map overlay tiles were not being sent during the full-sync event for late-joining clients in some network conditions.
- **Weed/pest/disease pressure penalties bypassing `nutrientCycles` guard** — crop-protection penalties applied even when the nutrient cycles setting was disabled. Now correctly gated.
- **Canopy field lookup for crop protection hooks** — the field lookup used for herbicide/insecticide/fungicide applications could return the wrong field when the spray position was near a border between two fields under the same farmland.
- **Rain effects never fired** — `environment.onWeatherUpdate` was being hooked with an incorrect API call that silently failed; leaching and seasonal nitrogen effects never ran. Fixed by using the correct `appendedFunction` target.
- **Soil initialisation timing** — moved from `Mission00.load` to `Mission00.onStartMission` to align with the FS25 EDC (Early Data Collection) pattern and avoid nil-ref errors during early load on some map types.
- **Duplicate HUD `loadLayout` call** — the layout was being loaded twice on mission start, causing a brief flicker and unnecessary log output.
- **`anchorTopCenter` text positions inside section panels** — incorrect Y offsets caused text to overlap section borders on non-default UI scales.

### Debug
- **Multi-boom sprayer weed pressure diagnostics** (Issue [#390](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/390)) — added `debug`-level logging in the sprayer hook for the case where `workAreaParameters.usage = 0` (no product consumed this frame) and when the VariableWorkWidth sections path is taken. Enable with `SoilDebug` in the developer console to capture the JD R4940 failure mode.

---

## [2.2.0.1] - 2026-05-17

### Added
- **Precision Farming integration** — Phase 1+2 bridge: custom fill types (UAN32, UAN28, ANHYDROUS, AMS, UREA, AN, MAP, DAP, POTASH, etc.) are injected into the PF nitrogen map so the PF HUD and application-rate recommendations account for SF products. A new **PF Compatibility Mode** setting gates the entire integration at runtime without a reload. Compatible with THPF Configurator when present.
- **Styled help dialogs** — In-game help (ESC › Help › Realistic Soil & Fertilizer) rebuilt with a two-column layout at 960 px width, a 4th **Help** button on the overlay toolbar, and corrected left-aligned body text.
- **Layer-specific map tooltip** — the overlay tooltip now adapts its label to whichever soil layer is currently selected (N / P / K / pH / OM / Weed) instead of always showing N.
- **Treatment dialog** — accessible from the HUD; shows recommended product and rate for each nutrient action (Repair/Maintain/Push) with colour-coded status.

### Fixed
- **COMPOST fill-plane texture overriding map-defined colour** (Issue [#392](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/392)) — SF's COMPOST fill type entry was declaring a `<textures>` block that overrode the game map's ground material. Removed the erroneous block; COMPOST now displays the correct farm-map surface.
- **N bar tick marks missing when PF is active** — the Precision Farming integration replaced the N fill-unit index, shifting the bar's expected index and hiding its tick marks. Fixed by resolving the index dynamically.
- **Sprayer hook field ID lookup** — the primary rootNode lookup could return the wrong field near farmland boundaries. Fallback chain improved; pH application logging corrected.
- **Per-zone pH variation preserved on map overlay** — recalculating the overlay was averaging all zone-cell pH values into a flat field pH, discarding the spatial pattern. Now reads per-cell values directly.
- **Bulk zone-cell network sync removed; unsampled overlay tiles dimmed** — sending all zone cells on every field-update event caused packet-size overflows on dedicated servers. Full join-sync is now bounded (max 500 cells); tiles with no local data are rendered at reduced opacity.
- **Straw chopping OM gain scaled by field size instead of concentration** — the OM bonus from straw incorporation was divided by `fieldAreaHa` instead of being a concentration value, making the bonus near-zero on large fields.
- **Crop protection pressure reduction raised to 50** across herbicide, insecticide, and fungicide to match the designed per-application impact.
- **Two harvest/sprayer bugs with PF active** — a nil-ref crash when PF modified the fill unit index before SF's harvest hook read it; a late-spawned combine not receiving the yield-modifier wrapper.
- **AMS fill-plane texture quality** — texture parameters now match the AN material (correct `unitSize`, `blendContrast`, `noiseScale` values).
- **FieldDetail colour crash** — `valueToLayerColor` returned nil for out-of-range values, causing a crash in the field detail panel renderer.
- **pH rounding consistency** — pH was displayed to 1 dp in the HUD tooltip but compared at full float precision in condition checks and the map overlay colour lookup, causing visual mismatches (e.g. tooltip showed 6.5 "Slightly Acidic" but map tile showed "Acidic"). All pH comparisons and colour mappings now round to 1 dp.
- **OM rounding before threshold checks** — same floating-point mismatch for OM percentage values; aligned to 1 dp.
- **Treatment dialog showing blended FERTILIZER for P/K fair actions** — the recommendation engine resolved compound NPK profiles to the generic `FERTILIZER` fill type when P or K was the limiting nutrient. Now correctly selects DAP/MAP (P) or POTASH (K).
- **Version dialog layout** — entries overflowed the dialog box on some font scales; box height expanded and line count corrected.

### Performance
- **Per-frame allocation reduction** — eliminated repeated `table.concat`, `string.format`, and `pairs()` calls on hot paths (sprayer hook, overlay render). Replaced with pre-allocated scratch tables and cached closures.
- **Map overlay and minimap restricted to owned fields** — previously iterated all fields on every frame including unowned/empty ones. Now skips fields the farm does not own, cutting overlay update time by ~60 % on large maps.

---

## [2.1.7.0] - 2026-05-15

### Fixed
- **Harvest nutrient depletion was silently broken** — `Combine.addCutterArea` passes `liters` as a 0/1 flag (crop present/absent), not actual grain volume. The depletion formula `(liters/1000) / fieldAreaHa` was effectively zero every call, meaning harvesting removed no N/P/K whatsoever. Replaced with an area-based formula: `factor = (areaHa / fieldAreaHa) × HARVEST_HA_FACTOR`, calibrated to the existing extraction-rate scale (8 000 L/ha proxy). Nutrients now correctly deplete across a full harvest.
- **Swath/windrow harvesting now depletes nutrients** — the swath mode path had a similar calibration mismatch (`× 6.0` factor vs. the required `× 8.0`). Both paths are now unified: area is always used, `liters` is ignored. Straw OM estimate also updated to match (6 000 → 8 000 L/ha proxy).
- **Oats tracked as a separate crop** — the extraction key `"oats"` did not match `g_fruitTypeManager`'s name `"oat"`, so oat harvests fell through to the generic cereal default. Fixed.
- **Cell report shows "No Data" on new games** (Issue [#383](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/383)) — `zoneData` cells are only created on fertilize/mow/plow events. On a fresh save every field showed "No cell data found". Now falls back to field-level averages (N/P/K/pH/OM) labelled **"Field avg"**. Once cell data exists from field activity, per-cell values display as normal.
- **Distance texture errors on dedicated servers** (Issue [#384](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/384)) — All 10 solid fill types registered in `densityMapHeightTypes.xml` were missing the `distance="..."` attribute on their `<textures>` element, causing `Failed to create density height map distance texture array` errors every session. Added appropriate vanilla `$data/fillPlanes/distance/*.dds` references to each affected fill type.
- **False warning on new careers suppressed** — `SettingsManager:getSavegameXmlFilePath()` logged a `WARNING: Savegame directory not available yet` on every new game load. This is expected behaviour (savegame directory is nil before the first save); downgraded to `DEBUG`.
- **`SoilDebug` console command now takes effect immediately** — `debugMode` was a server-shared setting, requiring a reconnect before changes propagated to the local client. Marked `localOnly` so the toggle is instant.

### Added
- **"Field avg" i18n key** — new translation key `sf_field_avg` added across all 26 languages for the cell report fallback label.

---

## [2.1.6.9] - 2026-05-15

### Fixed
- **HUD layout file moved to `modSettings/` (was savegame directory)** (Issue [#375](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/375)) — `_hud.xml` was written to the savegame directory, which is inaccessible to clients on dedicated servers and resolves to a non-existent `Savegame0` path before the first save. Now written to `modSettings/FS25_SoilFertilizer/HUD/hud.xml` (per-player, always writable).
- **HUD visibility toggle now saves immediately** — Pressing J to show/hide the HUD only persisted on game close; if the save failed (e.g., dedicated server), the state was lost. Now saved immediately on toggle.
- **`modSettings` folder name corrected** (was `modsSettings`) — Both `SettingsManager` and `SoilHUD` were writing to the wrong directory name, meaning per-player settings and HUD layout were never landing in the correct FS25 folder.
- **Organic Matter clamped to [0, 10] on all write paths** (Issue [#378](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/378)) — Corrupted `soilData.xml` entries (e.g. from a conflicting mod) could store negative `organicMatter` values that were loaded without validation and displayed as negative percentages in the HUD. Three paths lacked a floor clamp: `loadFromXMLFile`, `applyFertilizer` (field level and zone cells), and zone cell deserialization in both network sync events. All OM writes now enforce `math.max(0, …)`. N/P/K XML load also gains explicit bounds to match the network validation already in place.

### Changed
- **`modSettings/` folder structure reorganized** — Files now grouped under `modSettings/FS25_SoilFertilizer/{Settings,HUD,Debug}/` for a cleaner per-mod layout.

### Added
- **Debug output files** — When debug mode is active, three files are written to `modSettings/FS25_SoilFertilizer/Debug/`:
  - `debug.xml` — buffered `SoilLogger.debug()` messages (flushed when debug mode is toggled off or the game session ends)
  - `field_dump.xml` — full nutrient snapshot for a single field (written each time `SoilFieldInfo <id>` is run)
  - `soil_export.xml` — snapshot of all tracked field data (written each time `SoilSaveData` is run)
- **Current-pass coverage tracker** — The HUD now shows spray-pass progress as `"Pass: 45% (Digestate)"` regardless of the native FS25 fertilizer density-map state. Farmers working a field already at 100% vanilla fertilizer state could no longer see which strips they had covered (soil doesn't darken further); the new tracker accumulates coverage area independently and displays the localized product name alongside the percentage. Turns green at the ≥70% full-coverage threshold. Resets on harvest; survives game-day rollovers mid-pass.

---

## [2.1.6.8] - 2026-05-14

### Fixed
- **Dedicated server HUD settings not persisting** (Issue [#374](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/374)) — Per-player `localOnly` settings (HUD visibility, position, colorblind mode, field info box, mini-report, etc.) were being written to and read from the savegame XML alongside server-shared settings. On dedicated servers, clients have no write access to the savegame directory, so these preferences could never persist. Fixed by excluding all `localOnly` schema entries from `saveSettings`/`loadSettings`. Those settings are now exclusively handled by `saveLocalSettings`/`loadLocalSettings`, which write to each client's user profile `modsSettings/` directory.
- **Mini-report cell overlay missing on dedicated servers** (Issue [#375](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/375)) — `showMiniReport` is a `localOnly` setting; same root cause as #374. Now correctly saved per-player.

### Translation
- **French (fr)** — Updated by native speaker Seb/Squall39: colorblind mode, field info box, and display description keys translated.

---

## [2.1.6.7] - 2026-05-14

### Fixed
- **Dedicated server ping spike during cultivating/plowing/mowing/seeding** (Issue [#370](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/370)) — tillage operations (`onCultivation`, `onPlowing`, `onStripTill`, `onMow`, `onSowing`) broadcast a `SoilFieldUpdateEvent` every game tick while the implement was active, with no rate limiting. On a dedicated server, cultivating a large field generated thousands of network events per minute, causing significant ping spikes. Throttled to a maximum of one broadcast per 5 seconds per field (same throttle already used for fertilizer application).
- **Liquid Fertilizer spraying `StreamWriteInt32: nil` crash** (Issue [#371](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/371)) — `SoilSprayerRateEvent:writeStream` and `SoilSprayerAutoModeEvent:writeStream` wrote `self.vehicleNetId` directly without nil protection. Added `or 0` / `or 1` fallbacks as defense-in-depth; the receiver gracefully drops the event when vehicleNetId 0 resolves to no object.
- **Dedicated server crash during sprayer rate sync** — `SoilSprayerRateEvent` and `SoilSprayerAutoModeEvent` were passing an i3d node handle (local integer) to `NetworkUtil.getObjectId` in `writeStream`, which always returned nil, causing a `streamWriteInt32: Argument 1 has wrong type. Expected: Int. Actual: Nil` crash. Fired every ~5 seconds during auto-rate updates, or on manual rate up/down input in multiplayer.
- **Dedicated server crash with dry fertilizer spreaders (urea)** — wide-boom passes generated thousands of zone cells via `markBoomCells`, overflowing the FS25 network packet size limit. Per-field update events now send 0 zone cells (clients reconstruct from field aggregate); join sync capped at 500 cells; field-level zone data capped at 1000 cells.
- **Soil map tiles not updating** after fertilizer application on dedicated server clients.

### Added
- **Colorblind Mode** — toggle in Display > Visibility settings. Replaces red/green status palette with orange/blue (Okabe-Ito) palette safe for deuteranopia and protanopia. Applies across soil map overlay, legend, HUD bars, cell tooltips, and all dialogs. Per-player setting.
- **Field Info Box toggle** — toggle in Display > Visibility settings. Show or hide the native FS25 Field Info panel soil nutrients block when standing on a field. Per-player setting, on by default.

---

## [2.1.5.7] - 2026-05-11

### Translation Update
- All 25 languages have been written in their respective language
- All 25 translations (627 keys per language) are synced to the english version


---

## [2.1.5.6] - 2026-05-09

### Added
- **Residue incorporation from tillage** ([#338](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/338)) — cultivators, disk harrows, plows, strip-till implements, and direct-drill seeders now release a small amount of organic matter and nutrients (N, P, K) when working post-harvest stubble back into the soil. This models the decomposition of chopped straw and root residues naturally occurring in real agriculture. Each tillage type has its own incorporation efficiency:

  | Tool | OM gain | N | P | K | Notes |
  |---|---|---|---|---|---|
  | Plow | +0.12 | +0.8 | +0.10 | +0.6 | Deepest burial, highest release |
  | Cultivator / disk harrow | +0.06 | +0.4 | +0.05 | +0.3 | Shallow mixing |
  | Strip-till / ridge tiller | +0.03 | +0.2 | +0.02 | +0.15 | Tilled strips only (~30% surface) |
  | Direct-drill seeder | +0.02 | +0.1 | +0.01 | +0.08 | Opener slot disturbance only |

- **New setting: Residue Incorporation** — toggle this feature on or off independently of the existing Plowing Bonus setting. Enabled by default.
- Added new cell report HUD (tracks per-cell)
- Added new settings option for cell report HUD
- Added new soil map cell dialog (shows detailed info on each cell)
- Improved mouseEvent in soil overlay

---

## [2.1.5.5] - 2026-05-08

### Fixed
- **Nutrient depletion on grass** — fixed a math error where depletion from mowing scaled linearly with field size instead of area percentage, causing massive nutrient drain on large fields (Issue #332).
- **Manual application rate ignored** — Sprayer usage calculations now correctly factor in the user's manual application rate (MAP) multiplier when speed-based consumption is active (Issue #333).

---

## [2.1.5.4] - 2026-05-08

### Fixed
- Issue with loading a bigBag with the front wheel loader

### Added
-  Weed canopy suppression and nutrient depletion


---

## [2.1.1.0] - 2026-05-06

### Fixed
- **Spray visual not appearing for custom fill types** — the visual effect hook was manually starting `FertilizerMotionPathEffect` objects with stale spline entity IDs, producing per-frame `getClosestSplinePosition` script errors and no visible spray. Removed the hook entirely: `ExtendedSprayerEffects` vehicles drive the nozzle shader plane automatically; plain `Sprayer` vehicles use the vanilla `updateSprayerEffects` path, which activates once `processSprayerArea` sets `lastSprayTime`.
- **Ground density map not updating for custom spray types** — `installDensityMapSprayHook` used `Utils.prependedFunction`, which runs our function *before* the original. Because `wap.sprayType` and `wap.sprayFillType` are set *inside* `onStartWorkAreaProcessing`, our spray-type remap was operating on nil values. Changed to `Utils.appendedFunction` so the vanilla index is remapped after the original populates it. Custom types (LIQUIDLIME, UAN32, etc.) now correctly write the ground colour overlay.

---

## [2.1.0.0] - 2026-05-06

### Added
- **Section Control support** ([#299](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/299), [#298](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/298)) — reads `spec_variableWorkWidth.sections[i].isActive` and scales nutrient credit to the fraction of boom actively spraying.
- **Per-section field attribution** ([#300](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/300)) — nutrient credit is distributed across each active boom section using its `maxWidthNode` world position, enabling accurate field attribution when a wide boom straddles a field boundary.
- **Weed pressure clears on seeding** ([#304](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/304)) — sowing a crop now resets weed pressure to zero, matching real-world practice where emergence suppresses weeds at the seedling stage. Cultivation weed reduction also raised from 20% to 100%.

### Fixed
- **Slurry & manure had near-zero soil effect** ([#311](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/311)) — LIQUIDMANURE, MANURE, and DIGESTATE were missing from the custom spray type LPS registration. They fell through to vanilla spray type LPS (often near-zero or undefined), causing `wap.usage` per frame to be tiny and nutrient gain/coverage to be negligible. All three now get `customLPS = 14000 / 36000 = 0.38889 L/s`, consistent with the calibrated rate-to-LPS formula used by all other custom types.
- **Coverage indicator severely under-reported** ([#309](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/309), [#296](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/296)) — cell-based tracker compared rootNode path against total field cells, making a 28 m boom look like a 1 m boom. Replaced with area-based tracking: `areaThisTick = liters / baseRate_per_ha`. Coverage now advances correctly regardless of boom width or working speed.
- **Harvest nutrient extraction too aggressive** ([#305](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/305)) — depletion was not normalised by field area, causing large fields to lose far more nutrients than small ones per unit of yield. Factor is now `(harvestedLiters / 1000) / fieldAreaHa`.
- **Biosolids and chicken manure couldn't load into manure spreaders** ([#308](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/308)) — fill unit patch now covers MANURE-base fill units as well as FERTILIZER-base, allowing these dry organic types to load from bags into manure spreaders.
- **Incorrect white granular texture on new fill types** ([#307](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/307)) — biosolids, dry chicken manure, and other new fill types now render with correct dark compost textures instead of the white granular default fallback.
- **Log file filled with position spam during field work** ([#312](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/312)) — per-frame cultivation, plowing, and sowing position messages demoted from `info` to `debug` level.

---

## [2.0.8.0] - 2026-04-30

### Added
- Nutrient levels (N/P/K), weed pressure, pest pressure, and disease pressure now directly reduce combine harvest yield — closes [#279](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/279). Previously all penalties were display-only; the combine hopper now receives fewer liters proportional to soil health. N/P/K deficit can reduce yield up to −50% (crop-dependent), weed −30%, pest −30%, disease −25%. All factors multiply together.
- HUD yield forecast and actual combine yield now use the same formula — the `~-20%` warning shown is exactly what hits the tank.

### Fixed
- Coverage cell count still wrong in existing saves — re-closes [#277](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/277). Three-layer fix: (1) scan priority order — `farmland.areaInHa` (from map XML, always set) is now primary; `field.areaHa` defaults to `1.0` in `Field.new()` and is truthy, which blocked the fallback; (2) XML load re-query — after loading each field from save, `fieldArea` is immediately refreshed from live farmland data, correcting stale `1.0` values in old saves automatically on next load with no new game required; (3) safety net at first spray — `totalFieldCells` lazy init re-queries live area for fields created mid-session.

---

## [2.0.7.0] - 2026-04-30

### Added
- Full i18n pass: every previously hardcoded English string is now an i18n key — HUD labels (pH, OM, ppm, Coverage, Compaction), sprayer rate panel (APP. RATE, BURN RISK warnings, Target), all in-game notifications (welcome banner, field init, Critical Care Alert, Soil Update, Fertilizer Burn, sync error), settings panel categories/section headers/chrome (Admin: YES/NO, Multiplayer, Single Player, back/reset/close buttons), all setting descriptions, all multi-option dropdown values, and all admin action item labels
- Added 100+ new translation keys to all 26 language files (translation_en.xml with native values; all other 25 files with `[EN]` placeholders ready for community translation)

### Fixed
- Coverage calculation ([#277](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/277)): field area now correctly reads `field.areaHa` / `field.farmland.areaInHa` per FS25 LUADOC, fixing coverage completing in ~1.5 minutes instead of full-season pace
- Sprayer rate ghost bar ([#278](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/278)): rate multiplier now passed through to `drawNutrientRow` so the projected ghost bar reflects the current application rate setting
- Post-harvest HUD alarm ([#279](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/279)): HUD now shows a neutral "Post-harvest · Fertilize" message on the day of harvest instead of an alarming penalty % from freshly depleted soil
- Weed pressure on grassland ([#273](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/273)): weed growth accumulation and yield penalty are now skipped for grass/poplar/non-row-crop fields

---

## [2.0.6.4] - 2026-04-29

### Changed
- Polish translation fully updated by community contributor @DanielloHQ — all previously English-only strings now translated natively

---

## [2.0.6.3]  - 2026-04-28

### Fixed
- Settings path fix for dedicated servers: `getUserProfileAppPath()` now always receives a properly-terminated path, preventing mangled `modsSettings` directory on some server builds ([#267](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/267))
- HUD drag no longer consumes right-mouse-button globally — RMB edit mode now only activates when the cursor is over the HUD panel, restoring normal cursor play elsewhere ([#258](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/258))

---

## [2.0.6.2]  - 2026-04-27

### Fixed
- Minor stability fixes and edge-case errors in soil state updates
- Improved HUD interaction handling in specific UI states

---

## [2.0.6.1]  - 2026-04-27

### Fixed
- Fixed issues with HUD behavior when toggled rapidly
- Resolved minor sync inconsistencies in multiplayer sessions

---

## [2.0.6.0] - 2026-04-26

### Fixed
- RMB cursor no longer appears when Soil HUD is hidden ([#242](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/242))
- Prevented unintended HUD drag activation while interacting with vehicles

---

## [2.0.5.0-beta] - 2026-04-26

### Improved
- General HUD responsiveness and usability improvements
- Better handling of field state updates during gameplay

### Fixed
- Minor UI bugs and interaction inconsistencies

---

## [2.0.4.0] - 2026-04-26

### Added
- Additional internal validation for soil data consistency

### Fixed
- Various bugs related to soil value updates and display

---

## [2.0.3.0] - 2026-04-25

### Improved
- Improved handling of crop/soil transitions between growth states

### Fixed
- Fixed edge cases where soil values could desync after field changes

---

## [2.0.2.0] - 2026-04-25

### Added

- **Per-cell soil compaction tracking** ([#231](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/231)): Compaction is now tracked individually per
  soil cell rather than per field, enabling finer-grained overlay visualization and more
  accurate subsoiler targeting.

### Fixed

- **BigBag diffuse map textures included in build**: PNG texture files for bigBag products
  were excluded from the mod ZIP by the build script; corrected so all diffuse maps are
  packaged correctly.

---

## [2.0.1.0] - 2026-04-25

### Added

- **Per-product label textures for big bags**: Each big bag product now has its own unique
  label texture (`_diffuse.png`) so products are visually distinguishable in-game.

- **Community translations** (RU/UK): Russian and Ukrainian localizations contributed by
  community members.

### Fixed

- **LPS calibration for custom spray types** (PR [#233](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/233) by @antler22): `registerCustomSprayTypes`
  was scaling custom LPS off the vanilla display rate (93.5 L/ha) instead of the actual drain
  rate (291.6 L/ha), causing a 3.12× over-drain on every custom fertilizer type. Fixed by
  deriving `customLPS = customRate / 36000` directly. All 22 custom spray types now drain at
  exactly their `BASE_RATES` values.

- **Stale VEHICLE context action event IDs** (PR [#233](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/233) by @antler22): SF was accumulating
  duplicate input event registrations on every vehicle mount and Courseplay seat-change,
  causing keys to fire 2–3× per press and HUD drag to toggle on then immediately back off.
  Fixed by purging all existing SF vehicle event IDs before each re-registration pass.

- **Big bag store icon textures**: Missing `.dds` store icon files added for affected big bag
  products.

---

## [2.0.0.0] - 2026-04-25

### Added

- **Soil Compaction System** ([#221](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/221)): Heavy vehicles (8 t or more) now compact the soil they
  drive over. Compaction accumulates per field (0–100%) and applies a nutrient extraction
  penalty of up to 20% at maximum compaction — compacted soil can't deliver its nutrients as
  effectively. Pass with a subsoiler to reduce compaction by 15 points per pass. Compaction
  decays naturally at 0.5 points per day. Tracked in the HUD (green/amber/red), visible as
  overlay layer 10, saved to `soilData.xml`, and fully synced in multiplayer. Togglable in
  settings (`compactionEnabled`).

- **Per-Cell Coverage Tracking** ([#223](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/223)): The sprayer now tracks which individual soil cells
  have been covered during an application pass. Coverage fraction is calculated and displayed
  in the HUD (`Coverage: X% / 70% min`). The fully-treated notification is now gated on
  reaching at least 70% field coverage — no more phantom "field treated" messages from a
  single-pass clip across a corner. Coverage data is synced in multiplayer.

- **Rebindable HUD Drag** ([#224](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/224)): HUD drag mode (right-click to reposition the overlay) is
  now a proper FS25 input action (`SF_HUD_DRAG`, default: RMB) instead of a hardcoded mouse
  check. Players can rebind it in the standard FS25 key bindings menu. The old
  `hudDragEnabled` toggle in settings has been removed — the action now covers it directly.


### Architecture

- **`src/utils/SoilUtils.lua`** (new): Shared `SoilUtils.isPlayerAdmin()` utility replaces
  three duplicated admin-check implementations across `SoilSettingsPanel`, `SoilSettingsUI`,
  and `NetworkEvents` ([#217](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/217)).


- **Load-order guard**: `SoilFertilityManager.new()` now asserts that `SoilFertilitySystem`,
  `HookManager`, and `Settings` are all loaded before construction, catching accidental
  source-order regressions immediately at startup ([#219](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/219)).

- **`updatePosition()` call narrowed**: `SoilSettingsPanel:requestChange()` now only calls
  `soilHUD:updatePosition()` for the `hudPosition` setting, not for every local-only setting
  change ([#218](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/218)).

---

## [1.9.9.3] - 2026-04-24

### Fixed

- **[#208](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/208) — Admin settings GUI not updating on dedicated server**: When an admin changed a setting, the broadcast excluded the sender's connection. The admin's own panel was never refreshed with the new value. The sender exclusion has been removed — all clients including the admin now receive the `SoilSettingSyncEvent` broadcast.

- **[#209](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/209) — Admin settings reset to defaults on dedicated server restart**: `settings:load()` was called during `SoilFertilityManager.new()`, before the savegame directory was set by the engine on dedicated servers. Settings always loaded from the wrong path and fell back to defaults. The load is now deferred to `deferredSoilSystemInit()` where `savegameDirectory` is guaranteed to be available.

- **BUG-03 — `SoilFullSyncEvent` hardcoded settings list**: The MP full sync event enumerated 15 settings by name in a hardcoded block. Any new setting added to `SettingsSchema` would be silently absent from MP join syncs. Replaced with schema-driven iteration over `SettingsSchema.definitions` — new settings are now synced automatically. Wire format is unchanged for the existing 15 settings.

- **BUG-05 — `VANILLA_SETTINGS` defined twice in `SoilSettingsUI`**: The list of 3 settings shown in the vanilla settings page was defined as a local variable twice — once before the callbacks (used by those functions) and once after a block of function definitions (the intended single definition, but unreachable as an upvalue). The duplicate was removed and the single declaration moved before all function definitions.

- **[#204](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/204) — Conflict with FS25_CropRotation**: When a crop was sown, `onSowing()` cleared `field.lastCrop = nil` to force a live `FieldState` detection in the HUD. However, `getFieldInfo()` already performs live `FieldState` detection regardless — the clearing was unnecessary. The side-effect was that `lastCrop` (previous season) and `lastCrop2` (season before) both reflected the same crop when the same crop was replanted, causing duplicate entries in the rotation history. Removed the `onSowing` clearing entirely; the sowing hook installation was also removed from `HookManager`.

- **Zombie updaters in `hookInstaller` and batch dispatcher**: Both the deferred hook installer and the MP field batch dispatcher used `return true` / `return false` to signal completion. FS25's `addUpdateable` system ignores return values — updaters run forever unless `g_currentMission:removeUpdateable(self)` is called explicitly. Both updated to call `removeUpdateable` at the correct completion/cleanup points.

---

## [1.9.9.1]  2026-04-23

### Fixed
- **Dedicated server join freeze/crash on large maps (255+ fields)**: full-sync no longer sends all field data in a single blocking packet. Fields are now streamed to the joining client in batches of 32 via SoilFieldBatchSyncEvent, spread across multiple frames with a 50 ms gap between batches. The settings handshake is sent immediately so the client retry timer is cancelled right away.



---

## [1.9.9.0]  2026-04-23

### Fixed
- **Mod Icon** has been updated/changed
- **Settings panel** its ADMIN page has been improved. Ouput will be shown in a popup, instead of just the console

---

## [1.9.8.0] - 2026-04-21

### Fixed
- **Spreader pallet unload**: All fillTypes were wrapped in an unnecessary `<pallets>` container element — removed it so the game can correctly recognize the `<pallet>` reference. Spreaders can now unload custom fertilizers as bigBag pallets on site by pressing the I key. (Thanks @61nian — PR [#202](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/202))
- **Sprayer pallet unload**: Liquid fillTypes (UAN32, UAN28, ANHYDROUS, STARTER, INSECTICIDE, FUNGICIDE, LIQUID_UREA, LIQUID_AMS, LIQUID_MAP, LIQUID_DAP, LIQUID_POTASH) now correctly unload as liquidTank pallets when pressing I key on a sprayer. Previously these were pointing to bigBag objects which have no liquid fill point.
- **LIQUIDLIME pallet**: Added missing pallet reference for LIQUIDLIME, which was registered as a sprayer fillType but had no pallet entry at all.

---

## [1.9.7.0] - 2026-04-19

### Added

- **Admin page inside the SHIFT+O settings panel**: The **Drain Vehicle** button in the
  SHIFT+O settings panel has been replaced by an **Admin** button. Pressing it opens a dedicated
  admin page listing every available console command with buttons to execute them directly —
  no need to open the developer console. Admin-only access in multiplayer is enforced as before.

### Fixed

- **Liquid sprayer visual effects**: Custom liquid fertilizers (UAN-32, UAN-28, Anhydrous
  Ammonia, Starter 10-34-0, Liquid Urea, Liquid AMS, Liquid MAP, Liquid DAP, Liquid Potash,
  Insecticide, Fungicide, Liquid Lime) now correctly show spray visual effects and sounds on
  any sprayer while active. The previous approach remapped fill types correctly at the Lua
  level but the underlying `FertilizerMotionPathEffect` pipeline requires C++-registered motion
  path data per fill type — silently producing no effect. The fix hooks `Sprayer.onUpdateTick`
  to call `setEffectTypeInfo` + `startEffects` directly using the nearest vanilla fill type
  as a proxy, bypassing the broken pipeline entirely.

- **SoilSettingsPanel field position crash**: The field detection helper used `x, z = 0, 0`
  as its default, causing `getFieldAtWorldPosition(0, 0)` to silently return wrong results
  (or crash) when player position was unavailable. Default changed to `nil` with an explicit
  guard (`if x == nil then return nil end`) and a `pcall` wrapper around the field lookup.

---

## [1.9.4.0] - 2026-04-19

### Added

- **Purchasable big bags for Compost, Biosolids, Chicken Manure, and Pelletized Manure**: All
  four organic fertilizers are now available as purchasable big bags in the shop. Previously
  these were only obtainable through on-farm production or compatible mods. Compost ($300),
  Biosolids ($500), Chicken Manure ($600), Pelletized Manure ($1000) — single-unit and
  multi-purchase options included.

- **Purchasable Liquid Lime IBC tank**: Liquid Lime is now available as a purchasable IBC-style
  liquid tank ($1200 / 2000 L) in the shop, consistent with other liquid fertilizer products.
  Apply with a sprayer to raise field pH.

### Fixed

- **Gypsum now correctly lowers soil pH**: The gypsum fertilizer profile had `pH=0.0` (no
  effect) while the Treatment dialog recommended applying it for alkaline fields (pH > 7.5).
  Gypsum now applies a −0.10 pH delta per application (~−0.25 pH shift at the 1500 kg/ha base
  rate), giving players an actual tool to manage alkaline soil. Fill type title updated from
  `(pH+)` to `(pH−)` across all 26 languages.

- **Tillage reduces weed, pest, and disease pressure**: Any cultivator or plow pass now reduces
  active weed, pest, and disease pressure on the field. Closes [#188](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/188).

---

## [1.9.3.0] - 2026-04-18

### Added

- **IBC Liquid Tanks replace big bag containers for liquid fertilizers**: UAN-32, UAN-28,
  Anhydrous Ammonia, Starter 10-34-0, Liquid Urea, Liquid AMS, Liquid MAP, Liquid DAP,
  Liquid Potash, Insecticide, and Fungicide are now available as IBC-style liquid tank objects
  in the shop instead of big bag pallets. The new objects are purpose-built for liquid products
  and provide a cleaner visual fit. Single-unit and multi-purchase options included for all types.

- **Purchasable Gypsum big bag**: Gypsum is now available as a purchasable big bag in the shop,
  consistent with other solid amendment products. Apply with a spreader to correct pH and
  improve soil structure.

- **`SoilDrainVehicle` console command**: Drains all custom fertilizer fill types from the
  current vehicle and all attached implements, refunding 50% of the product value. Liquid
  sprayers have no built-in way to be emptied in FS25 — this command is the escape hatch
  so players can switch products without discarding an entire tank load.

- **Soil report treatment action strings** (all 26 languages): The soil report now shows
  specific product recommendations per nutrient deficit — e.g. "Apply UAN32, UREA, or
  ANHYDROUS" for low nitrogen — and rotation status labels (Legume Bonus, Fatigue, OK).

---

## [1.9.2.0] - 2026-04-18

### Fixed

- **HUD crashes every frame when transparency set to Clear or Light**: `setTextShadow()` does
  not exist in FS25's Lua sandbox. Calling it aborted the draw function every frame, making the
  entire HUD panel invisible at low transparency levels. Both calls removed.

- **Background color not visually changing with transparency**: The HUD panel background was
  pure near-black (`{0.05, 0.05, 0.05}`) regardless of the selected color theme. Changing
  transparency on a near-black background produces no perceptible difference. The background is
  now lightly tinted by the active color theme accent so transparency changes are clearly visible.

---

## [1.9.1.0] - 2026-04-18

### Added

- **Large map support (16x and custom sizes)**: The soil map overlay now scales its polygon fill
  step proportionally to the terrain size. A 2048m map uses a 10m step (unchanged); an 8192m
  map uses a 40m step, keeping the total sample count bounded and preventing budget exhaustion
  on oversized maps. Cache keys include the step value so large-map and standard-map results
  never collide.

- **Dedicated server HUD settings persistence**: HUD appearance settings (position, transparency,
  color theme) are now saved to and loaded from a per-player local file using
  `getUserProfileAppPath()`. Previously these settings were stored only in the server savegame
  XML, which clients on a dedicated server cannot write — meaning they reset to defaults on
  every reconnect. The local file is always saved and loaded regardless of server/client role,
  and local values take precedence over server-received values.

---

## [1.9.0.0] - 2026-04-18

### Added

- **Per-area PDA overlay coloring via sparse cell grid**: The in-game map overlay now colors
  each field area using a sparse `zoneData` cell grid rather than a single centroid dot. Each
  grid cell is sampled individually so fields with mixed soil status display correctly.

### Fixed

- **Spray ground overlay rendering**: Spray ground overlays now render correctly end-to-end,
  including per-pixel soil map overlay support.

- **Lua local scope crash in overlay sampling**: `getCellLayerValue` was called before it was
  defined in local scope inside `updateSamplePoints`, causing a nil crash on certain map loads.
  Reordered so the local function is declared before use.

---

## [1.8.9.0] - 2026-04-17

### Fixed

- **AI empty-tank vanilla fallback**: AI workers no longer get stuck when custom fill tanks run
  empty. The system falls back to vanilla behavior correctly instead of throwing errors.

- **Fill plane and volume textures**: Fill plane and volume textures now display correctly for
  custom fill types (UREA, UAN32, DAP, etc.).

- **Spray visuals**: Spray visual effects now play correctly for all custom fertilizer types
  under all application conditions.

- **Missing German translation strings**: All German strings that previously showed `[EN]`
  placeholders are now fully translated and the EN placeholders removed.

### Improved

- **Translation sync**: UK, RU, and several other language files updated with corrected strings.

- **Polygon sample budget raised**: `MAX_POINTS` raised from the previous value to 15,000,
  allowing larger fields to display full polygon fill coverage without truncation.

---

## [1.8.8.0] - 2026-04-17

### Changed

- **PDA screen reduced to two tabs**: The Soil Map tab has been removed. The interactive soil
  map is fully available from the native PDA Map (ESC → Map) via the sidebar overlay controls.
  The PDA page now has two focused tabs — **Farm Overview** and **Treatment Plan** — each taking
  half the tab bar width for a cleaner layout.

- **Treatment Plan button now navigates correctly**: Clicking "Treatment Plan" from the in-game
  map sidebar overlay now lands directly on the Treatment Plan tab. Previously the tab would not
  switch automatically — the user had to click the tab manually. Root cause: `onOpen()` was
  resetting the active tab from `self.activeTab` *after* the tab was set from the static call.
  Fixed by pre-setting `page.activeTab` before `goToPage()` fires the lifecycle.

- **Map sidebar buttons replaced**: The sidebar "Dev Note (NOT WORKING YET)" button has been
  replaced with three actionable buttons — **Cycle Layer** (cycles through overlay layers),
  **Treatment Plan** (opens the PDA Treatment tab directly), and **Disable Overlay** (hides the
  overlay). The sidebar no longer shows any placeholder or broken controls.

- **Help button label**: The bottom-bar "Dev Note" button on the PDA screen is now labelled
  **Help**, opening the soil quick-reference card (nutrients, thresholds, treatment guide).

### Fixed

- **Overlay tiles fill edge-to-edge at any zoom**: Tile size is now computed per-frame using
  two world-to-screen probe points so tiles expand with zoom and leave no grid gaps. Previously
  tiles showed visible seams when zooming in.

- **Field detail dialog showing all values red**: Status comparisons were case-sensitive. The
  `getFieldInfo()` API returns capitalized strings (`"Good"`, `"Fair"`, `"Poor"`); comparisons
  used lowercase literals and always fell to the `else` (red) branch. Fixed with `.lower()`.

- **mouseEvent crash on first PDA Map open after using Farm Overview**: `IngameMapPreviewElement`
  crashed at `setCustomLayout` when `ingameMap` was nil. The paging element routes mouseEvents
  to all registered pages including hidden ones; the minimap's `ingameMap` is only set when the
  map tab is opened. Fixed by guarding `mouseEvent` to short-circuit when `ingameMap == nil` or
  the element is not visible. (Moot after the map tab removal, but the guard remains for safety.)

### Improved

- **UX color consistency**: All four dialogs (Field Detail, Treatment, Report, Field Detail) now
  use the same `{0.25,0.85,0.25}` / `{0.90,0.82,0.18}` / `{0.88,0.25,0.25}` palette.
  Previously each dialog had slightly different green/amber/red values.

- **Treatment dialog "OK" text**: Optimal status rows now show **OK** instead of
  "Optimal — No action needed." for a cleaner, faster scan.

---

## [1.8.7.0] - 2026-04-16

### Fixed

- **Custom fill types blocked from vehicle-to-vehicle transfer**: UREA, UAN32, DAP, and all
  other custom fill types could only be loaded from a shop big-bag trigger. Discharging from
  an auger wagon into a spreader, or pumping from a tanker into a sprayer, was blocked because
  `Dischargeable:dischargeToObject` calls `getFillUnitSupportsFillType` before transferring —
  a method some FS25 versions route through a C++ fast-path that bypasses the `supportedFillTypes`
  table we already patched. Fixed by also hooking `FillUnit.getFillUnitSupportsFillType` directly:
  if the vehicle supports the vanilla base type (FERTILIZER or LIQUIDFERTILIZER), it now also
  returns `true` for the matching custom type.

### Improved

- **Soil map overlay fills entire field polygon**: The overlay previously placed a single dot at
  each field's centroid. It now fills the full field area with a 15-metre grid of coloured tiles
  so field boundaries are clearly visible on the map. Field polygon vertices are read from the
  i3d scene via `Field.polygonPoints`; a ray-casting point-in-polygon test filters out grid
  positions outside the boundary. Polygon points are cached per-field and invalidated on layer
  switch. Dot size reduced from 14 px to 10 px; per-tile borders removed for performance.
  `MAX_POINTS` raised from 850 to 3000 to accommodate larger maps.

---

## [1.8.6.0] - 2026-04-16

### Fixed

- **Soil map overlay dots never rendered**: The `onDrawPostIngameMap` callback targeted by
  the soil map hook does not exist as a callable method in FS25. The appended function was
  registering silently but never firing, so no overlay dots were drawn on the in-game map.
  Fixed by hooking `IngameMapElement.draw` at the class level instead. The new hook walks
  the parent chain (up to 6 levels) to locate the `InGameMenuMapFrame` that owns the element,
  then checks whether the soil map page is active before delegating to `SoilMapOverlay:onDraw()`.

- **Lua multi-return truncation in `getMapRenderBounds`**: Chained `return` of multiple
  return values caused single-value truncation in some call sites. Fixed by assigning to
  explicit local variables before returning.

- **`worldToScreenPosition` inconsistent layout reference**: Now consistently uses
  `fullScreenLayout` instead of mixing layout sources across callers.

- **`pointPool` nil crash**: The pool system was referenced in `delete()` but never
  initialized, causing a nil-index crash on mod unload. Removed entirely; `samplePoints`
  is now a plain table reset on each update cycle.

- **Overlay sampling switched to per-field centroids**: `updateSamplePoints` was using a
  34×34 world-space grid, producing dots at arbitrary coordinates unrelated to actual fields.
  Now samples one dot per tracked field using `fsField.posX / posZ` — one correctly coloured
  dot per field, no off-field scatter.

- **Missing `cycleLayer()` and `requestGenerate()` on `SoilMapOverlay`**: The PDA screen and
  map frame called these methods but they were never defined, causing nil-call crashes when
  switching layers or refreshing the overlay. Both are now implemented.

- **Sidebar layer toggle re-click behaviour**: Re-clicking the currently active overlay layer
  button now turns the overlay off (toggles to layer 0) instead of re-selecting the same layer.

- **Dark border on map dots**: Added a 1-pixel dark outline to each overlay dot for readability
  against light terrain colours.

---

## [1.8.5.0] - 2026-04-15

### Added
- Add ownership check and seasonal pings for critical field alerts

### Fixed
- Resolve PDA crash and disappearing fill types on dedicated servers
- Improve RMB mouse event handling
- Remove wonky layer rendering in the PDA Screen
- Update all translation files
- Various minor bug fixes and development documentation updates

## [1.8.2.0] - 2026-04-13

### Changed

- **Soil PDA Screen refactoring**: Overhauled the PDA Menu (`K` key) for better context sensitivity.
- **Map Sidebar Jump**: The Soil Map tab now includes a field list sidebar. Clicking a field centers the mini-map on that field immediately.
- **Treatment Sidebar Stats**: The Treatment Plan tab sidebar now shows summary counts for fields needing fertilizer, herbicide, insecticide, or fungicide.
- **UI UX Improvements**: Removed the redundant "Fields" tab, consolidating its data into the Overview and Map sidebars.

## [1.8.1.0] - 2026-04-12

### Fixed

- **Issue [#150](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/150) — Nil crash in update loop**: `SoilNetworkEvents_SendSprayerRate` was called
  unconditionally at three sites in `SoilFertilityManager.lua`. If `NetworkEvents.lua` failed to
  load (missing file, load-order problem, or earlier Lua error), all three call sites would crash
  the per-frame update loop. Added nil guards (`if SoilNetworkEvents_SendSprayerRate then`) at
  all three sites.

- **Issue [#125](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/125) — AI helper BUY mode fertilizer never consumed**: The
  `FillUnit.addFillUnitFillLevel` hook in `HookManager.lua` had an incorrect function signature —
  the `farmId` argument (first real param after `self`) was missing, shifting every subsequent
  argument by one position. The `fillLevelDelta >= 0` guard was evaluating `fillUnitIndex >= 0`
  (always true), so the BUY-mode intercept fired on every call without ever matching a valid price
  or consuming product. Fixed the full signature to
  `(vehicle, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData)`,
  corrected all internal references, and added a reliable backup refill path inside the sprayer
  area hook with per-vehicle timestamp deduplication to prevent double-charging.

- **PDA field filter ownership check**: The "Owned Fields" filter in the PDA screen was calling
  `g_fieldManager:getFieldByIndex(fieldId)` where `fieldId` is actually a farmland ID (as stored
  by the sprayer hook via `field.farmland.id`). `getFieldByIndex` returns nil for farmland IDs,
  so every field silently passed the filter regardless of ownership. Fixed to use
  `g_farmlandManager:getFarmlandOwner(fieldId)` directly.

- **PDA filter footer button label not syncing**: After toggling the ownership filter, the footer
  button label remained stale ("All Fields" / "Owned Fields" out of sync with actual state).
  `_refreshFilterButtons()` now also updates `menuButtonInfo[2].text` and calls
  `setMenuButtonInfo()` so the footer button reflects the current filter state.

---

## [1.8.0.0] - 2026-04-11

### Added

- **PDA InGameMenu page** (`SoilPDAScreen`) — a full dedicated page in the FS25 in-game menu
  (Shift+P shortcut), built on the `TabbedMenuFrameElement` pattern matching FS25 native screens.
  Left sidebar shows live farm-wide averages for N, P, K, pH, Organic Matter, and crop pressure
  counts. Three sub-tabs:
  - **Soil Map tab** — shows the active overlay layer name and description, a colour legend, and
    a button to jump directly to the interactive soil map.
  - **Fields tab** — `SmoothList` of all tracked fields with per-field N/P/K/pH/OM columns and
    an overall status indicator. Click any row to open the Field Detail dialog.
  - **Treatment Plan tab** — urgency-sorted list of fields needing attention with the primary
    deficiency identified. Minor-urgency fields grouped at the bottom.

- **Field Detail dialog** (`SoilFieldDetailDialog`) — per-field popup (opened from Fields or
  Treatment tab) showing all nutrient values with Good/Fair/Poor colour-coded status, weed/pest/
  disease pressure with active-treatment asterisk notation, last crop, and crop rotation status
  with Legume Bonus / Fatigue / OK indicators.

- **`menuIcon.dds`** — dedicated 512×512 white-on-transparent silhouette icon for the PDA tab
  header and tab bar, keeping the mod browser `icon.dds` visually distinct from the in-game UI.

- **Refreshed `icon.dds`** — new flat-design badge icon: seedling with three leaves sprouting
  from a soil mound, "SOIL &amp; FERTILIZER / Realistic Mod" text on dark background, consistent
  with the FS25 mod collection visual style.

- **`SF_SOIL_PDA` action** — new ONFOOT input action bound to Shift+P, opens the PDA page
  directly from anywhere in-game.

- **84 new localisation keys** across all 26 supported languages (en, de, fr, nl, it, pl, es,
  ea, pt, br, ru, uk, cz, hu, ro, tr, fi, no, sv, da, kr, jp, ct, fc, id, vi) covering all PDA
  screen text, map legend labels, treatment plan descriptions, and Field Detail dialog strings.

- **`build.py`** — Python build/deploy script as an alternative to `build.sh`.

### Fixed

- **Field Detail dialog access** — Fixed `onClickFieldRow` and `onClickTreatmentRow` missing
  from PDA screen controller, enabling the detailed per-field popup to open upon clicking rows.
- **Liquid Big Bag icons** — Replaced missing/generic liquid big bag shop icons with the
  proper big-bag silhouette icons for AMS, Urea, MAP, DAP, and Potash.
- **Issue [#149](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/149)** — Resolved bug where fertilizer would disappear on savegame reload and
  implement emptying was blocked due to missing pallet definitions in `fillTypes.xml`.
- **Applicator detection** — Cached `isFertilizerApplicator` result on the vehicle object,
  significantly reducing CPU overhead during field application.

- **Pressure color thresholds aligned with Constants**: The HUD's `drawPressureRow` and the Soil
  Report's `getPressureColor` function were using hardcoded 25/60 boundaries. These now use
  `SoilConstants.WEED_PRESSURE.LOW` (20) and `MEDIUM` (50) — matching the tier boundaries used
  by the yield-penalty system and the recommendation engine. A field at 22% weed pressure was
  previously showing Green despite a -5% yield penalty already being applied.

- **HUD panel height calculation**: The `calculateHeight()` guard `(info.weedPressure or 0) >= 0`
  was always true (pressure never goes negative), so the panel added an extra line of height even
  when weed/pest/disease pressure was exactly zero. Fixed to `> 0`.

- **Soil Report `getOverallStatus` dead check**: The `val >= 0` guard on pressure values in the
  overall-status worst-case ranking was also always true. Fixed to `val > 0` for clarity.

- **Console commands bypass MP network layer**: All setting-change console commands
  (`SoilSetFertility`, `SoilSetDifficulty`, `SoilEnable`, etc.) were directly mutating
  `g_SoilFertilityManager.settings` without going through the network event layer. In
  multiplayer, server-side console changes would not broadcast to clients. All commands now route
  through `SoilNetworkEvents_RequestSettingChange()` so the full server → broadcast flow is
  respected. A local `requestSettingChange` helper in `SoilSettingsGUI.lua` provides a
  graceful fallback when the network layer is not yet initialised.

- **`SoilFieldForecast` urgency score inconsistency**: The console command was calculating
  urgency as an NPK-only average deficit, which differed from the score used to sort fields in
  the Soil Report (which includes pH, weed, pest, and disease factors). The command now calls
  `soilSystem:getFieldUrgency()` so the reported score matches the in-game display.

- **`SoilFieldForecast` missing from help output**: The command was registered and functional
  but not printed by `soilfertility` / `SoilHelp`. Added.

---

## [1.6.0.3] - 2026-04-11

### Fixed

- **Multiplayer stream desync (critical)**: `SoilFullSyncEvent:writeStream` was writing 19
  values per field but `readStream` was reading 20 — `burnDaysLeft` was read but never written.
  On a server with any burn-damaged fields, a joining client's field data would be silently
  corrupted for every field after the first. Fixed by adding the missing
  `streamWriteInt32(streamId, field.burnDaysLeft or 0)` to the write path, and storing the
  read value in the field table. The same field was also missing from `SoilFieldUpdateEvent`.

- **Fertilization notification permanent silencing**: `fertNotifyShown[fieldId]` stored `true`
  on first notification — meaning a field would never produce another notification for the rest
  of the save, not just for the current day. The flag now stores the current game day and is
  checked with `~= today`, matching the documented per-day intent.

- **Dead `SoilFertilityManager:draw()` method**: The method existed but was never called —
  `main.lua` hooks `FSBaseMission.draw` directly to `sfm.soilHUD:draw()`. Removed.

- **Dead constant reference in `getFieldUrgency`**: Used `SoilConstants.PH_NORMALIZATION.OPTIMAL`
  which does not exist in Constants.lua. Replaced with the correct literal `6.5` (optimal pH
  mid-point of the 6.5–7.0 neutral band).

---

## [1.6.0.2] - 2026-04-11

### Fixed

- **HUD sprayer rate display for low-volume products**: Insecticide and Fungicide (very low base
  rates) were rounding to `0 L/ha` or `0 gal/ac` at lower multiplier settings. The formatter now
  uses one decimal place when the product's base rate is below 10.0, ensuring the rate panel
  always shows a meaningful, non-zero value.

- **HERBICIDE missing from sprayer rate BASE_RATES**: HERBICIDE had no entry, so the HUD fell
  back to the DEFAULT rate config regardless of the product loaded in the sprayer. Added a
  dedicated HERBICIDE entry with the correct base rate and `liquid` unit type.

- **AI purchase refill hook return value (issue [#125](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/125))**: The `FillUnit.addFillUnitFillLevel`
  hook was returning `true` in BUY mode to signal "handled" — but the FS25 hook convention
  requires returning the original function's return value to keep the call chain intact.
  Changed to return the original `fillDelta` from the base function, which allows other hooks
  and the engine to proceed correctly.

---

## [1.6.0.1] - 2026-04-10

### Fixed

- **AI purchase refill BUY mode detection (issue [#125](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/125))**: The hook was checking three spec
  fields that do not exist in FS25 (`isSprayerBuyingFillType`, `isFillPurchaseActive`,
  `reloadState`), causing the check to always return false and the tank to deplete normally.
  Fixed to use the correct FS25 pattern: `vehicle:getIsAIActive()` combined with
  `g_currentMission.missionInfo.helperBuyFertilizer` (and the slurry / manure equivalents).

- **Coverage buffer requirement extended to crop protection products (issue [#143](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/143))**: The 90%
  coverage buffer introduced in 1.6.0.0 was only applied to nutrient fertilizers. Insecticide,
  Fungicide, and Herbicide were still applying their effects instantly on any area pass. The
  buffer now covers all five product categories (N, P, K, herbicide, insecticide/fungicide).

- **Instant field notification removed**: A `g_currentMission:addIngameNotification()` call
  fired immediately on mod load, producing a confusing popup before the player had done anything.
  Removed.

- **FS25_MoistureSystem added to compatibility list** (issue [#141](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/141)).

---

## [1.6.0.0] - 2026-04-10

### Added

- **Crop rotation tracking** (issue [#132](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/132)): Each field now tracks the last 3 harvested crops
  (`lastCrop`, `lastCrop2`, `lastCrop3`). On harvest the history shifts automatically so the
  full 3-season sequence is always available. History is saved to `soilData.xml` and synced
  to all clients in multiplayer.

- **Rotation bonus**: When a legume (soybean, peas, or beans) follows a non-legume in the
  previous season, the field receives +0.5 N per day for the first 3 days of spring, modelling
  nitrogen fixation carry-over. The counter is saved and survives mid-spring save/reload.

- **Mono-crop fatigue multiplier**: When the same crop is harvested two seasons running, all
  nutrient extraction rates are multiplied by 1.15× — an extra 15% depletion for that harvest
  to represent diminishing returns from repeated cropping. Does not stack beyond 2 seasons.

- **Crop rotation status in the Soil Report**: The per-field recommendation panel now shows one
  of three rotation status strings alongside the nutrient advice: *Rotation Bonus* (legume bonus
  active), *Fatigue: Same Crop* (mono-crop penalty in effect), or *Rotation: OK* (healthy
  alternation, no effect either way).

- **Crop Rotation toggle**: New server-authoritative setting in the mod settings panel. When
  disabled, no bonus or fatigue fires but the crop history is still recorded so turning it back
  on takes effect immediately.

- **Six new purchasable fertilizer fill types** (issue [#133](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/133)): GYPSUM, COMPOST, BIOSOLIDS,
  CHICKEN_MANURE, PELLETIZED_MANURE, and LIQUIDLIME are now formally registered in
  `fillTypes.xml`. They appear in the price table, are added to the SPREADER and SPRAYER fill
  type categories, and are routed through the nutrient hook with their pre-existing profiles.
  Note: big bag shop objects for the new organic types are planned for a future patch.

- **Liquid equivalents for all custom fertilizer types** ([#137](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/137)): Added LIQUID_UREA, LIQUID_AMS,
  LIQUID_MAP, LIQUID_DAP, and LIQUID_POTASH to support sprayer application, with big bags and
  BUY-mode support.

### Fixed

- **Calibrated application rates for custom fill types** (issue [#142](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/142)): Custom fertilizers like
  UAN32, Anhydrous, and Urea now have their `litersPerSecond` calibrated to match their
  intended `BASE_RATES` (e.g. 60 L/ha for UAN32) instead of inheriting the vanilla 93.5 L/ha
  rate. This ensures tank consumption and nutrient application are perfectly synced with
  the HUD display and agronomic profiles.

- **Required full field coverage for fertilizer effect** (issue [#143](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/143)): Realism improvement.
  Nutrient levels and crop protection effects (Insecticide/Fungicide/Herbicide) no longer
  update instantly. Instead, applied liters are buffered per product. Effects are only
  credited to the field once ~90% of the volume required for full coverage has been
  applied. Buffers are cleared daily, requiring same-day completion for credit.

- **Improved HUD rate resolution for low-volume products**: Insecticide and Fungicide
  (which have very low base rates) no longer display as "0 L/ha" or "0 gal/ac" in the 
  sprayer rate panel. The HUD now shows 1 decimal place for products with base rates
  below 10.0, ensuring the rate control is responsive and accurate.

- **Pressure values displayed as 4-digit percentages in Soil Report**: Weed, pest, and disease
  pressure are stored internally as 0–100. The report dialog was multiplying them by 100 again,
  producing values like "6500%" and always rendering red status regardless of actual severity.
  Fixed in table rows and in the detail view. *(Silent bug — only visible when any pressure > 0.)*

- **Overall status badge ignores pH, OM, and bio-pressures**: The "Good / Fair / Poor" status
  shown in the Soil Report table and the HUD title bar only considered N/P/K. A field with poor
  pH, low organic matter, or high weed/pest/disease pressure could still show "Good". Now all
  five soil parameters plus all three pressure scores are included in the worst-case ranking.

- **Farm Health % uses uneven scoring weights**: Farm Health was calculated using 100 / 55 / 10
  for Good / Fair / Poor. The non-linear gap between Fair (55) and Poor (10) made the percentage
  drop unnaturally sharp. Changed to 100 / 50 / 0 — a clean linear scale.

### Improved

- **Soil Report detail view fully localized**: Several status labels in the field detail panel
  were hardcoded English strings. All replaced with `tr()` calls backed by new i18n keys.

- **Weed/pest/disease HUD rows extracted to `drawPressureRow()` helper**: Removed ~60 lines
  of duplication; color scale simplified to 3 levels to match N/P/K bars.

---

## [1.5.1.0] - 2026-04-09

### Fixed

- **HUD text missing in 24 languages (issue [#130](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/130))**: The HUD overlay was showing raw
  translation key names (`sf_hud_title`, `sf_hud_fallow`, `sf_hud_yield`, etc.) for
  every language except English and Ukrainian. Root cause: 13 `sf_hud_*` keys were
  added when the live HUD was implemented but never propagated to the 24 non-EN
  language files. English text added as fallback in all 24 files — proper per-language
  translations can follow in community PRs.
  Credit: sava4903-coder for identifying this in issue [#130](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/130).

- **Mouse event double-firing in vehicles (issue [#130](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/130))**: The `soilMouseHandler`
  registered via `addModEventListener` was not checking the `eventUsed` flag before
  processing mouse input and was not returning it afterward. In vehicles where the
  camera or another listener had already consumed an RMB event, the HUD would still
  try to enter edit mode from a stale or mis-positioned cursor.
  Fix: `soilMouseHandler` now guards on `not eventUsed` and returns the flag.
  `SoilHUD:onMouseEvent` now accepts and returns `eventUsed`, and uses
  `Input.MOUSE_BUTTON_RIGHT` / `Input.MOUSE_BUTTON_LEFT` constants (LUADOC-verified).

---

## [1.5.0.0] - 2026-04-09

### Added

- **Yield Forecast (issue [#81](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/81))**: Live yield penalty estimate now displayed in the HUD while
  standing in a field. Shows the projected harvest loss (e.g. `Yield ~-18%`) based on current
  N/P/K deficits, crop sensitivity tier, and the `YIELD_SENSITIVITY` constants. Suppressed for
  non-cropland states (fallow, grass).

- **Urgency-Based Soil Report Sorting**: The Soil Report (K key) now sorts fields by urgency
  score — a combined deficit across N/P/K/pH/weed/pest/disease (0–100). Most critical fields
  appear at the top. The yield penalty estimate is also shown in the recommendation column.

- **Critical Field Alerts**: Once per in-game year, the mod fires a notification when any
  owned field's urgency score exceeds the configured threshold. Alerts appear during spring to
  give players time to act before the growing season.

- **`SoilFieldForecast <fieldId>` console command**: Prints a detailed yield forecast for the
  specified field — projected penalty %, urgency score, crop sensitivity tier, and a text
  recommendation for which nutrients need attention most.

- **Plowing hook diagnostic logging**: The workArea nil-guard in the plowing hook now emits a
  `debug`-level log entry when it fires, making it visible under `SoilDebug` if a cultivator
  dispatches an unexpected workArea format. Aids verification under non-standard FS25 dispatch modes.

### Fixed
- **Mod Compatibility (issue [#128](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/128))**: Removed the aggressive safe-mode check entirely. The
  trigger was mis-firing on harmless visual mods (tire tracks, decal placeables), causing users
  to lose all soil simulation without any real conflict present. Soil simulation now always runs.

## [1.4.9.0] - 2026-04-08

### Fixed
- **Settings UI Crash**: Fixed a game crash occurring when players attempted to reset mod settings, replacing an invalid GUI API call (`showYesNoDialog`) with the correct FS25 `YesNoDialog.show` API.
- **Field Detection Accuracy**: Improved the field ID detection from work areas by replacing the geometric center averaging with accurate parallelogram midpoint calculations.

## [1.4.8.0] - 2026-04-07

### Fixed

- **Soil Report "Syncing" timeout in multiplayer (issue [#120](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/120))**: Joining clients on
  multiplayer servers would often hang on the "Syncing field ownership data..."
  screen, eventually timing out after 15s. This occurred because the ownership
  synchronization check was too restrictive, especially on maps where no land is
  owned by default (survival starts).

  Fix: Enhanced `isOwnershipSynced` in `SoilReportDialog.lua` with a multi-stage
  verification process. The sync check now correctly identifies server-sent initial
  state by verifying if *any* land on the map is owned by *any* farm. Added a
  fallback that considers sync complete once the mission is fully started or the
  game HUD is visible. Increased the sync retry window to 30s (15 attempts) for
  better reliability on heavily modded dedicated servers.

---

## [1.4.7.0] - 2026-04-07

### Fixed

- **"BUY" refill mode not working with custom fill types** (issue [#125](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/125)): AI workers and
  Courseplay now correctly use the "Buy" helper setting with custom products. Fixed
  a bug where the tank would still deplete or the worker would stop when empty.
  The system now correctly intercepts consumption, charges the farm account, and
  tricks the engine into continuing application without depleting physical stock.

---

## [1.4.6.0] - 2026-04-06

### Fixed

- **Soil HUD showing wrong or stale crop name (issue [#123](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/123))**: The HUD was displaying
  the crop from a previous harvest (e.g. "Oat" from 3-4 harvests ago) or showing
  "Fallow" even when a live crop was growing. Root cause: `SoilFertilitySystem:getFieldInfo()`
  called `fsField:getFieldState()`, which **does not exist in FS25**. `FieldState` is a
  standalone class that must be instantiated with `FieldState.new()` and populated via
  `fieldState:update(centerX, centerZ)`. The silent `pcall` failure meant live crop
  detection always fell through to the stale `field.lastCrop` value.

  Fix 1 (`SoilFertilitySystem.lua`): Replace the non-existent `getFieldState()` call with
  the correct `FieldState.new()` + `:update(fsField.posX, fsField.posZ)` pattern.

  Fix 2 (`HookManager.lua`): Add `installSowingHook()` on `SowingMachine.processSowingMachineArea`
  to clear `field.lastCrop = nil` whenever seeds are planted. This prevents the previous
  harvest's crop from showing during the gap between sowing and the next FieldState poll,
  and ensures "Fallow" is only shown on genuinely bare/cultivated ground.

---

## [1.4.5.0] - 2026-04-06

### Fixed

- **Herbicide / insecticide / fungicide instantly resetting pressure to 0% from any dose**
  (issue [#121](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/121)): The crop protection hook fired on every game frame (~60×/sec) while the
  sprayer was active. Each frame applied the full `HERBICIDE_PRESSURE_REDUCTION` (30 pts),
  `INSECTICIDE_PRESSURE_REDUCTION` (25 pts), or `FUNGICIDE_PRESSURE_REDUCTION` (20 pts),
  meaning a single pass across a field applied the reduction hundreds of times and drove
  weed / pest / disease pressure to zero regardless of how much product was actually used.

  Fixed with a **per-field, per-day throttle**: each of `onHerbicideApplied`,
  `onInsecticideApplied`, and `onFungicideApplied` now records the in-game day of the last
  application per field (`herbicideAppliedDay`, `insecticideAppliedDay`, `fungicideAppliedDay`
  tables on `SoilFertilitySystem`) and exits immediately if it has already fired today for
  that field. One application event per field per in-game day — consistent with the existing
  `fertNotifyShown` pattern used for NPK notifications.

- **Double-application of INSECTICIDE / FUNGICIDE crop protection** (related to [#121](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/121)): Both
  fill types are declared in `FERTILIZER_PROFILES` with `pestReduction` / `diseaseReduction`
  markers, causing `applyFertilizer` to route them to `onInsecticideApplied` /
  `onFungicideApplied` internally. The hook additionally called those same functions directly
  via the `pestEffectiveness` / `diseaseEffectiveness` path — a second application in the same
  frame. Fixed by only using the direct path for products that are **not** in
  `FERTILIZER_PROFILES` (e.g. vanilla `HERBICIDE` / `PESTICIDE` fill types with no profile
  entry). Profile-based products are handled exclusively through `applyFertilizer`.

---

## [1.4.4.0] - 2026-04-06

### Fixed

- **NPK not increasing after field scan with any fertilizer** (critical): The sprayer hook was
  gated on `spec.workAreaParameters.isActive`, which FS25 only sets `true` when the vanilla
  density map pixel actually changes. Fields already fully fertilised in the base-game system
  return `changedArea = 0`, so `isActive` stayed `false` and every fertiliser application was
  silently skipped — nutrients never changed. Fixed by replacing the `isActive` guard with a
  check on `sprayFillLevel > 0` and `usage > 0`: if the sprayer has product and consumed some
  this frame, the nutrient application is now always recorded regardless of vanilla terrain state.

- **`getDifficultyName()` crash on MP client sync** (Bug [#3](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/3)): On full-sync receive, the settings
  object is a plain Lua table populated field-by-field from the network stream — not a `Settings`
  class instance. Calling `:getDifficultyName()` on it threw `attempt to call a nil value`.
  Replaced with an inline `diffNames[]` table lookup. Also converted the surrounding `print()`
  to `SoilLogger.info()`.

- **`g_currentMission` nil crash in daily soil update** (Bug [#8](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/8)): Seasonal effects block accessed
  `g_currentMission.environment` without first guarding `g_currentMission` itself. Added the
  missing nil check — safe on dedicated server shutdown and level reload.

- **Stale full-sync retry handler after level reload** (Bug [#10](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/10)): The module-level
  `fullSyncRetryHandler` persisted across level reloads in its `success` or `failed` state.
  A reconnecting MP client would call `start()` on a completed handler, which guards on
  `state == "pending"` and is a no-op — the client never re-synced. Fixed by calling
  `reset()` before `start()` in `SoilNetworkEvents_RequestFullSync()`.

- **`math.randomseed()` polluting global PRNG during bulk field scan** (Bug [#13](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/13)): Calling
  `math.randomseed(fieldId * 67890)` on every lazy field creation resets the shared Lua random
  state. During the initial scan many fields are created in the same frame, each overwriting the
  previous seed before its random numbers are drawn. Replaced with a Lua 5.1-compatible
  deterministic LCG hash that produces stable, per-nutrient variation for each field without
  touching the global PRNG.

- **`listAllFields()` always printing `"?"` for FieldManager field IDs** (Bug [#27](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/27)): The function
  used `field.fieldId` which is always `nil` in FS25. Fixed to use `field.farmland.id`, consistent
  with the rest of the codebase. Converted all `print()` calls in the function to `SoilLogger`.

- **DIAG / debug `print()` calls spamming the log in production** (Bug [#26](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/26)): Several raw
  `print("[SoilFertilizer DIAG] ...")` calls in `SoilHUD`, `SoilReportDialog`,
  `SoilFertilityManager`, and `SoilFertilitySystem` fired unconditionally for every player in
  every session. Replaced with `SoilLogger.debug()` / `.warning()` / `.error()` so they are
  gated behind `debugMode` and go through the centralised logger.

---

## [1.4.3.0] - 2026-04-05

### Fixed

- Remaining 10000L changed to 1000L
- Improved (extended) pest duration and added to correct hook
- Cleaned modDesc (& becomes &amp;)


---

## [1.4.2.0] - 2026-04-04

### Fixed

- **Missing text entries and declaration in registerCustomSprayTypes**: Both new added types where missing their title entry. They are also added into `constants` and declared propperly.

---

## [1.4.1.0] - 2026-04-04

### Added

- **Purchasable big bags for Insecticide and Fungicide**: Both crop protection products are now available as 10,000 L big bags in the shop (same system as all other custom fertilizer types). Insecticide: $1,200/bag; Fungicide: $1,300/bag. Multi-buy available up to 8 bags at a time.

---

## [1.4.0.0] - 2026-04-04

### Added

- **Field Health System — Pest & Disease Pressure**: Two new per-field pressure scores (0–100) join the existing weed pressure system, each independently toggleable in settings.

  | Pressure | Max Yield Penalty | Controlled by | Resets via |
  |----------|-------------------|---------------|------------|
  | **Pest** | −20% | `INSECTICIDE` spray | Harvest event |
  | **Disease** | −25% | `FUNGICIDE` spray | Dry weather (3+ days) |

  Both grow daily with seasonal multipliers (pests peak in summer; disease peaks in spring and fall). Crop susceptibility varies by type — potatoes and canola are most vulnerable. Rain accelerates both. Active protection suppresses regrowth for 10–12 days after application.

- **Two new fill types**: `INSECTICIDE` (liquid, $1.20/L) and `FUNGICIDE` (liquid, $1.30/L), registered in `fillTypes.xml` and accepted by any liquid sprayer. Crop protection products are routed through the sprayer hook alongside fertilizers — they reduce pressure but do not add N/P/K.

- **Settings**: `Pest Pressure` and `Disease Pressure` toggles added to the mod settings page (default on). Both are server-authoritative in multiplayer and fully synced to joining clients.

- **HUD**: Pest and disease pressure rows appear below weed pressure when the respective settings are enabled, using the same colour tiers (green/amber/red).

- **Soil Report**: Pest and disease alerts added to the per-field report — flagged when pressure exceeds the medium threshold.

- **Save/load**: `pestPressure`, `diseasePressure`, `insecticideDaysLeft`, `fungicideDaysLeft`, and `dryDayCount` persisted per field in `soilData.xml`. Backward-compatible — old saves load cleanly with all new values defaulting to 0.

- **Multiplayer**: `SoilFullSyncEvent` and `SoilFieldUpdateEvent` extended with pest and disease fields. Stream symmetry preserved.

---

## [1.3.3.0] - 2026-04-04

### Fixed

- **Settings page showing raw key names instead of translated text**: All UI text lookups now correctly use the mod-scoped i18n instance. Root cause: `g_currentModName` is only valid at mod load time, not at UI construction time. The mod name is now captured in a local variable (`SF_MOD_NAME`) at file load time and used in all translation lookups across `SoilSettingsUI`, `SoilReportDialog`, and `UIHelper`. Affected 1.3.2.0 users on all languages.

---

## [1.3.2.0] - 2026-04-04

### Fixed

- **Sprayer visuals for custom fill types**: Custom fertilizers (UAN32, UAN28, Anhydrous, Starter, UREA, AMS, MAP, DAP, Potash) now correctly show spray/spread effects on all sprayer and spreader types, including PF-modded equipment. Root cause: vanilla runtime checks inside `Sprayer.onEndWorkAreaProcessing` compared against hardcoded `FillType`/`SprayType` constants, which never matched our custom indices. Fix wraps the function with a temporary global table swap (pattern identified from community testing) so all vanilla checks transparently pass for our fill types — originals are restored immediately after the call.

- **Save data not written on first career start**: `loadSoilData()` was called in the `SoilFertilityManager` constructor before `savegameDirectory` was set by the game engine. Moved to `deferredSoilSystemInit()` which runs after the mission info is fully populated.

- **Multiplayer clients never received full soil state on join**: `SoilNetworkEvents_RequestFullSync()` was implemented but never called. Now triggered in `loadedMission()` for MP clients, with the existing 3-attempt retry handler backing it.

- **Compatibility mode removed**: The previous read-only mode was causing field data to silently disappear on dedicated servers. The mod now always runs fully independently and tracks NPK/OM/pH on its own.

- **fillTypeCategory name collision**: Categories named `FERTILIZER` and `LIQUIDFERTILIZER` conflicted with vanilla entries. Renamed to `SPREADER` and `SPRAYER`.

### Thanks

Special thanks to **seb** from the FS25 Modding Community Discord for testing and identifying the spray effects solution.

---

## [1.1.4.0] - 2026-03-15

### Added

- **Auto-Rate Control**: Sprayers and spreaders can now automatically adjust application rates based on field nutrient gaps (Alt+Z).
- **Gypsum Support**: Added Gypsum fertilizer type with pH stabilization and organic matter benefits.
- **Enhanced HUD**: Updated sprayer rate panel to show AUTO status and target nutrients.

## [1.0.7.1] - 2026-02-21

### Fixed

#### No field data on dedicated servers (Issue [#40](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/40))

- **FIXED**: Removed the read-only mode that was silently activated on dedicated servers, causing all field data to disappear. The mod now always runs in independent mode — field data is always written and synced normally.

- **FIXED**: Clients on dedicated servers never received initial field data
  - Field data was previously only broadcast to clients on harvest or fertilizer events
  - On a freshly loaded server with no activity, clients had empty field tables for the entire session
  - `scanFields` now calls new `broadcastAllFieldData()` immediately after a successful scan
  - `loadFromXMLFile` also calls `broadcastAllFieldData()` after load to re-sync clients following a save/load cycle

- **ADDED**: `broadcastAllFieldData()` — iterates all tracked fields and broadcasts each to every connected client via `SoilFieldUpdateEvent`

- **ADDED**: `onClientJoined(connection)` — sends full field state to a single newly-joined client; must be wired into the multiplayer connection-accepted handler (follow-up required)

- **FIXED**: Field ID resolution priority in `scanFields` corrected
  - Previous priority: `field.fieldId` → loop key → `field.id` → `field.index`
  - Corrected priority: `field.fieldId` → `field.id` → `field.index` → loop key (last resort)
  - The loop key is an internal table index that does not reliably match the in-game field ID on all maps, causing data to be stored and looked up under the wrong key

- **FIXED**: `hasFarmland` check in `scanFields` no longer gates field initialization
  - Unowned fields are valid and must be tracked so data is ready when ownership is later assigned via `onFieldOwnershipChanged`

---

## [1.0.7.0] - 2026-02-18

### Changed

#### SoilHUD — Converted to Legend/Reference Panel
- **CHANGED**: `SoilHUD` is now a static **legend/reference panel** instead of a live per-field data display
  - The full-detail field view is now properly served by the Soil Report dialog (K key)
  - The HUD no longer needs player position, farmland detection, or field polling each frame
  - Eliminates all timing-sensitive field-detection code that could crash or return stale data

#### New HUD Content
- **Keys section**: `J = Toggle HUD` and `K = Soil Report` always visible for discoverability
- **Color-coded nutrient legend**: Good / Fair / Poor thresholds (N>50/P>45/K>40, N>30/P>25/K>20) matching `STATUS_THRESHOLDS` in Constants exactly
- **pH reference**: `pH ideal: 6.5 - 7.0` as a quick agronomic reminder

#### Code Cleanup (`src/ui/SoilHUD.lua`)
- **REMOVED**: `getCurrentPosition()` — position detection no longer needed
- **REMOVED**: `getFarmlandIdAtPosition()` — farmland lookup no longer needed
- **REMOVED**: `findFieldAtPosition()` with 3-tier field detection fallback — no longer needed
- **SIMPLIFIED**: `draw()` reduced to basic visibility guards only (no player/vehicle checks)
- **SIMPLIFIED**: `drawPanel()` is now a pure static renderer — no field data, no PF integration, no farmland fallback logic
- File reduced from 719 lines to 202 lines

### Fixed
- **FIXED**: `self:getActionName("SF_SOIL_REPORT")` call in `drawPanel()` that would have caused a runtime error (method did not exist on SoilHUD)

---

## [1.0.6.5] - 2026-02-17

### Summary
Polish pass by XelaNull (PR [#33](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/33)). Localization improvements, dialog stacking fixes, pagination cleanup, and mod compatibility corrections.

### Fixed
- Mod compatibility: settings tab integration, J-key binding race condition, slow-server field initialization (Issue [#21](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/21))
- Settings corruption on dedicated servers with 100+ mods loaded

### Changed
- Localization string improvements across all 10 supported languages
- Dialog stacking and close-order correctness for `SoilReportDialog`
- Pagination layout and display for the Soil Report

---

## [1.0.6.0] - 2026-02-16

### Changed
- Version bump to 1.0.6.0 consolidating v1.0.5.x hotfixes as stable baseline

### Fixed
- Settings corruption when 100+ mods are loaded on dedicated servers

---

## [1.0.5.2] - 2026-02-16

### Fixed
- Settings UI corruption on dedicated server clients

---

## [1.0.5.1] - 2026-02-16

### Fixed
- 6 critical HUD and multiplayer issues identified post-1.0.5.0 release

### Changed
- Improved HUD field detection accuracy
- Added status-enriched (color-coded Good/Fair/Poor) soil display in HUD

---

## [1.0.5.0] - 2026-02-16

### Summary
**Major robustness and quality improvements** based on comprehensive code audit comparing against proven NPCFavor and UsedPlus mod patterns. All changes are **backwards compatible** - existing savegames will work without modification.

**13 issues fixed**: 1 HIGH severity (crash prevention), 6 MEDIUM severity (robustness), 6 LOW severity (code quality)

### Added

#### Console Commands
- **NEW**: `SoilListFields` - List all tracked fields with soil data and compare against FieldManager
  - Useful for debugging field initialization issues
  - Displays N/P/K/pH/OM values for all fields

#### Constants
- **NEW**: `SoilConstants.PLOWING` section with `MIN_DEPTH_FOR_PLOWING` constant
  - Replaced magic number (0.15) with documented constant
  - Improves maintainability for plowing depth threshold

### Changed

#### Critical Crash Prevention (HIGH Severity)
- **FIXED**: Replaced all `assert()` calls with graceful error handling + user dialogs
  - Prevents game crashes if modules fail to load
  - Shows informative dialogs to players: "Soil & Fertilizer Mod failed to load..."
  - Mod degrades gracefully instead of crashing entire game
  - Affected: `SoilFertilityManager.lua` (3 locations)

#### Robustness Improvements (MEDIUM Severity)
- **FIXED**: Added nil validation to plowing hook `workArea` parameter
  - Prevents crash from nil workArea in cultivator operations
  - Validates array structure before access
  - Affected: `HookManager.lua` line 267

- **FIXED**: Wrapped all Logger `string.format()` calls in `pcall()` with fallback
  - Prevents crashes from mismatched format arguments
  - Falls back to `tostring()` if format fails
  - Adopted NPCFavor proven pattern
  - Affected: `Logger.lua` (all 4 functions: debug, info, warning, error)

- **FIXED**: Added defensive nil checks to HUD `fieldInfo` access
  - Prevents crash from nil fieldInfo in edge cases
  - Shows "Initializing..." message gracefully
  - Affected: `SoilHUD.lua` lines 622-625

- **FIXED**: Network corruption detection and sanitization for multiplayer field data
  - Validates all incoming network data (N/P/K/OM/pH, lastHarvest, fertilizerApplied)
  - Detects NaN, negative values, out-of-range values
  - Logs warnings: "Corrupt MP data: Field X nitrogen out of range... clamping"
  - Shows user notification: "Soil Mod: Data sync issue detected. Please report if this persists."
  - Sanitizes corrupt data to safe defaults before applying
  - Affected: `NetworkEvents.lua` SoilFullSyncEvent:readStream()

- **FIXED**: 3-tier field scan retry with frame-based fallback and graceful failure
  - **Tier 1**: Time-based retry (10 attempts, 2 sec intervals) - existing system
  - **Tier 2**: Frame-based fallback (600 frames = ~10 sec) - NEW
    - Triggers if `g_currentMission.time` is frozen
    - Shows notification: "Field initialization delayed. Trying alternative method..."
    - Shows success notification: "Field initialization successful!" if recovery works
  - **Tier 3**: Graceful failure - NEW
    - Dialog: "Could not initialize fields... The mod has been disabled for this session only. Please restart the game to try again."
    - Disables mod for current session (non-persistent)
    - Mod re-enables automatically on next launch
  - Affected: `SoilFertilitySystem.lua` initialization + update loop

- **FIXED**: Settings validation now rejects unknown settings (fail-secure pattern)
  - `SettingsSchema.validate()` returns `nil` for unknown settings instead of passing through
  - Logs rejection: "Validation rejected unknown setting: XYZ"
  - Prevents future code from accidentally accepting invalid settings
  - Affected: `SettingsSchema.lua`, validation flow

#### Code Quality (LOW Severity)
- **FIXED**: HUD color theme bounds validation
  - Clamps `hudColorTheme` to range 1-4
  - Logs warnings for out-of-bounds values
  - Falls back to theme 1 if invalid
  - Affected: `SoilHUD.lua` line 391

- **IMPROVED**: Hook-level debug logging consistency
  - Added debug logging to fertilizer hook (matches harvest hook pattern)
  - Both hooks now log: "Hook triggered: Field X, ..."
  - Helps diagnose hook execution issues
  - Affected: `HookManager.lua` harvest + fertilizer hooks

- **IMPROVED**: Network value clamping on read (NPCFavor pattern)
  - Added `math.max`/`min` clamping to all network reads
  - Clamps to `SoilConstants.NUTRIENT_LIMITS` ranges
  - Applied to both `SoilFullSyncEvent` AND `SoilFieldUpdateEvent`
  - Double layer of protection: clamp on read (network) + validate on apply (settings)
  - Affected: `NetworkEvents.lua` (2 event classes)

### Developer Notes
- **Testing Time**: ~4 hours comprehensive, ~1 hour critical path (see `TESTING_CHECKLIST_v1.0.5.md`)
- **Code Changes**: 9 files modified, ~300 lines added/modified
- **Patterns Adopted**: NPCFavor pcall wrapping, network clamping, field retry with exponential backoff
- **Breaking Changes**: None - fully backwards compatible

---

## [1.0.4.1] - 2026-02-15

### Fixed
- Hook installation timing issue causing 3 of 5 hooks to fail
- Improved deferred initialization using mission updateables
- Field scan retry mechanism for delayed FieldManager availability

---

## [1.0.4.0] - 2026-02-14

### Fixed
- Multiplayer sync improvements
- HUD visibility feedback enhancement
- Mod compatibility improvements
- Critical gameplay balance and UX issues

---

## [1.0.3.0] - 2026-02-13

### Fixed
- HUD overlay rendering issues

---

## [1.0.2.0] - 2026-02-12

### Added
- Initial multiplayer support
- Admin-only settings enforcement
- Field ownership change handling

### Changed
- Improved settings persistence
- Enhanced compatibility system

---

## [1.0.1.0] - 2026-02-11

### Added
- Console commands for all settings
- Field info console command
- Debug mode toggle

### Fixed
- Settings validation edge cases
- HUD positioning issues

---

## [1.0.0.0] - 2026-02-10

### Added
- Initial release
- Core soil nutrient tracking (N/P/K/OM/pH)
- Crop-specific depletion on harvest
- Fertilizer type profiles (liquid, solid, manure, slurry, digestate, lime)
- Weather effects (rain leaching)
- Seasonal effects (spring nitrogen boost, fall nitrogen loss)
- Plowing bonus for organic matter
- Difficulty levels (Simple/Realistic/Hardcore)
- In-game HUD with customization (position, color, font, transparency)
- Settings GUI integration
- 10-language localization (en, de, fr, pl, es, it, cz, br, uk, ru)
- Save/load persistence for soil state
- Save/load persistence
- Console commands

---

## Version Numbering

Format: `MAJOR.MINOR.PATCH.HOTFIX`

- **MAJOR**: Breaking changes, major feature additions
- **MINOR**: New features, significant changes (backwards compatible)
- **PATCH**: Bug fixes, minor improvements
- **HOTFIX**: Critical fixes between patches

---

*For detailed testing procedures, see `TESTING_CHECKLIST_v1.0.5.md`*

---
