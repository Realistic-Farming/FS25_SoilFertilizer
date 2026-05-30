# FS25_SoilFertilizer - Developer Guide

**Version**: 2.2.5.0
**Last Updated**: 2026-05-30

---

## Table of Contents

1. [Getting Started](#getting-started)
2. [Architecture Overview](#architecture-overview)
3. [Adding New Crops](#adding-new-crops)
4. [Adding New Fertilizers](#adding-new-fertilizers)
5. [Adding New Settings](#adding-new-settings)
6. [Network Synchronization](#network-synchronization)
7. [Hook System](#hook-system)
8. [HUD System](#hud-system)
9. [Testing Your Changes](#testing-your-changes)
10. [Common Gotchas](#common-gotchas)
11. [Soil Density Map Layers](#soil-density-map-layers)
12. [Build & Release](#build--release)

---

## Getting Started

### Development Setup

1. **Clone Repository**
   ```bash
   git clone https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer.git
   cd FS25_SoilFertilizer
   ```

2. **Install to FS25**
   - Copy entire folder to `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\`
   - Or run `py build.py --deploy` to build the zip and deploy automatically

3. **Enable Developer Console**
   - Edit `game.xml` in FS25 root
   - Set `<development>` to `<controls>true</controls>`
   - Press `~` in-game to open console

4. **Enable Logging**
   - Use `SoilDebug` console command
   - Check `log.txt` in FS25 documents folder

### File Structure

```
FS25_SoilFertilizer/
├── modDesc.xml              # Mod manifest & translations
├── icon.dds                 # Mod icon
├── fillTypes.xml            # Custom fill type definitions
├── CLAUDE.md                # Project architecture guide
├── DEVELOPMENT.md           # This file
├── src/
│   ├── main.lua                    # Entry point & lifecycle hooks
│   ├── SoilFertilityManager.lua    # Central coordinator
│   ├── SoilFertilitySystem.lua     # Core soil simulation logic
│   ├── SprayerRateManager.lua      # Auto-rate control logic
│   ├── config/
│   │   ├── Constants.lua           # All tunable values
│   │   └── SettingsSchema.lua      # Settings definitions
│   ├── settings/
│   │   ├── Settings.lua            # Settings domain object
│   │   ├── SettingsManager.lua     # XML save/load (server + local per-player)
│   │   ├── SoilSettingsUI.lua      # In-game UI generation
│   │   └── SoilSettingsGUI.lua     # Console commands
│   ├── hooks/
│   │   ├── HookManager.lua         # Game engine hook lifecycle
│   │   └── SoilMapHooks.lua        # In-game map overlay hooks
│   ├── network/
│   │   └── NetworkEvents.lua       # Multiplayer sync
│   ├── ui/
│   │   ├── SoilHUD.lua             # Always-on HUD panel overlay
│   │   ├── SoilSettingsPanel.lua   # HUD settings sub-panel (position, theme, transparency)
│   │   ├── SoilPDAScreen.lua       # PDA screen (K key) — Farm Overview + Treatment Plan tabs
│   │   ├── SoilMapOverlay.lua      # In-game map polygon fill overlay
│   │   ├── SoilLayerSystem.lua     # Overlay layer definitions (N/P/K/OM/pH)
│   │   ├── SoilFieldDetailDialog.lua  # Field detail popup dialog
│   │   ├── SoilTreatmentDialog.lua    # Treatment recommendation dialog
│   │   └── SoilReportDialog.lua    # Full-farm soil report dialog
│   ├── integrations/
│   └── utils/
│       ├── Logger.lua              # Centralized logging
│       ├── AsyncRetryHandler.lua   # Retry pattern utility
│       ├── SoilUtils.lua           # Shared admin-check and common helpers (v2.0)
│       └── UIHelper.lua            # UI element creation
```

---

## Architecture Overview

### Module Loading Order

`main.lua` loads modules in strict dependency order:

1. **Utilities & Config**: Logger, AsyncRetryHandler, Constants, SettingsSchema, SoilUtils
2. **Core Systems**: HookManager, SoilMapHooks, SprayerRateManager, SoilFertilitySystem, SoilFertilityManager
3. **Settings**: SettingsManager, Settings, SoilSettingsGUI
4. **UI**: UIHelper, SoilSettingsUI, SoilLayerSystem, SoilMapOverlay, SoilFieldDetailDialog, SoilTreatmentDialog, SoilReportDialog, SoilPDAScreen, SoilSettingsPanel, SoilHUD
5. **Network**: NetworkEvents
6. **Integrations** (optional DLC bridges): SeeAndSprayIntegration

**Important**: Respect this order when adding new modules.

### Central Coordinator Pattern

`SoilFertilityManager` (exposed as `g_SoilFertilityManager`) owns all subsystems:

```lua
g_SoilFertilityManager
  ├── settings          : Settings instance
  ├── settingsManager   : SettingsManager instance
  ├── soilSystem        : SoilFertilitySystem instance
  ├── soilHUD           : SoilHUD instance
  ├── soilPDAScreen     : SoilPDAScreen instance
  ├── soilMapOverlay    : SoilMapOverlay instance
  └── Network events registered globally
```

### Data Flow

**Harvest Event**:
1. `FruitUtil.fruitPickupEvent` fires (FS25)
2. `HookManager` intercepts via hook
3. Calls `SoilFertilitySystem:onHarvest(fieldId, fruitType, liters)`
4. System calculates nutrient depletion
5. Updates `fieldData[fieldId]` internal state
6. If multiplayer server: broadcasts `SoilFieldUpdateEvent` to clients

---

## Adding New Crops

Crops have different nutrient extraction rates. To add a new crop:

### Step 1: Add Extraction Rates to Constants

Edit `src/config/Constants.lua`:

```lua
SoilConstants.CROP_EXTRACTION = {
    -- Existing crops...

    -- Add your new crop here
    ["yourcrop"] = {    -- Must match FS25 fruit type name (lowercase)
        N = 15,         -- Nitrogen extraction per 1000L harvested
        P = 8,          -- Phosphorus extraction
        K = 10,         -- Potassium extraction
    },
}
```

**Calibration Guidelines**:
- **High N crops**: Wheat, Barley, Corn (leafy growth) — N: 15-20
- **High P crops**: Corn, Soybeans (energy/seeds) — P: 8-12
- **High K crops**: Potatoes, Sugar Beets (roots/tubers) — K: 12-18
- **Nitrogen-fixing**: Soybeans, Peas (legumes) — N: 5-8 (they fix their own)

### Step 2: Test

1. Plant your crop in FS25
2. Note field nutrients before harvest: `SoilFieldInfo <fieldId>`
3. Harvest the crop
4. Check nutrients after: `SoilFieldInfo <fieldId>`
5. Verify depletion matches your rates × difficulty multiplier

**No other code changes needed** — the system automatically picks up crops from Constants.

---

## Adding New Fertilizers

Fertilizers restore nutrients with different ratios.

### Step 1: Add Fertilizer Profile to Constants

Edit `src/config/Constants.lua`:

```lua
SoilConstants.FERTILIZER_PROFILES = {
    -- Existing fertilizers...

    -- Add your new fertilizer here
    ["YOURFERTILIZER"] = {  -- Must match FS25 fill type name (UPPERCASE)
        N = 25,             -- Nitrogen added per 1000L applied
        P = 15,             -- Phosphorus added
        K = 10,             -- Potassium added
        pH = 0,             -- pH change (positive increases, negative decreases)
        OM = 0,             -- Organic matter change
    },
}
```

### Step 2: Register the Fill Type

If the fertilizer uses a custom fill type (not vanilla), register it in `HookManager:installEffectTypeHook()` by adding to the `remap` table so spray effects work correctly.

### Step 3: Test

1. Note field nutrients: `SoilFieldInfo <fieldId>`
2. Apply your fertilizer in FS25
3. Check nutrients after: `SoilFieldInfo <fieldId>`
4. Verify nutrients increased by your rates

---

## Adding New Settings

The mod uses a **schema-driven settings system**. One definition in `SettingsSchema.lua` auto-generates:
- XML save/load
- Default values
- In-game UI
- Console commands
- Network sync

### Step 1: Add to SettingsSchema

Edit `src/config/SettingsSchema.lua`:

```lua
SettingsSchema.definitions = {
    -- Existing settings...

    -- Add your new setting here
    {
        id = "yourSetting",              -- Internal ID (camelCase)
        type = "boolean",                -- "boolean" or "number"
        default = true,                  -- Default value
        min = 1,                         -- (Optional) Min value for numbers
        max = 10,                        -- (Optional) Max value for numbers
        uiId = "sf_your_setting",        -- UI/translation key (snake_case)
    },
}
```

**Important**: Do NOT reorder existing entries — this breaks XML save/load compatibility with existing saves.

### Step 2: Add Translations to modDesc.xml

Edit `modDesc.xml` in the `<l10n>` section. Add entries for all 26 languages:
en, de, fr, nl, it, pl, es, ea, pt, br, ru, uk, cz, hu, ro, tr, fi, no, sv, da, kr, jp, ct, fc, id, vi

```xml
<!-- Short label for UI toggle -->
<text name="sf_your_setting_short">
    <en>Your Setting</en>
    <de>Deine Einstellung</de>
    <!-- ... all 26 languages -->
</text>

<!-- Long description/tooltip -->
<text name="sf_your_setting_long">
    <en>Enable/disable your new feature</en>
    <de>Aktiviere/deaktiviere deine neue Funktion</de>
    <!-- ... all 26 languages -->
</text>
```

### Step 3: Use in Code

The setting is now automatically available:

```lua
-- Access anywhere via g_SoilFertilityManager.settings
if g_SoilFertilityManager.settings.yourSetting then
    -- Your feature code here
end
```

**That's it!** The UI, save/load, network sync, and console commands are all auto-generated.

---

## Network Synchronization

### Multiplayer Architecture

- **Server-authoritative**: Server owns soil data and settings
- **Client sync**: Clients receive updates via network events
- **Admin-only**: Only admin users can change settings

### Network Events

| Event | Direction | Purpose |
|-------|-----------|---------|
| `SoilSettingChangeEvent` | Client → Server | Request setting change (admin validated) |
| `SoilSettingSyncEvent` | Server → Clients | Broadcast setting change |
| `SoilRequestFullSyncEvent` | Client → Server | Request full state on join |
| `SoilFullSyncEvent` | Server → Client | Send all settings + field data |
| `SoilFieldUpdateEvent` | Server → Clients | Update specific field after harvest/fertilize |

### Full Sync Flow

1. Client joins server
2. `loadedMission()` in `main.lua` calls `SoilNetworkEvents_RequestFullSync()`
3. Server responds with `SoilFullSyncEvent` containing all settings + all field data
4. Client applies received data
5. If sync fails, client retries via `AsyncRetryHandler` (3 attempts, 5-second intervals)

### Adding New Network-Synced Data

If you need to sync new data types:

1. **Add to SoilFullSyncEvent** (`NetworkEvents.lua`):
   ```lua
   -- In writeStream:
   streamWriteString(streamId, tostring(self.yourNewData))

   -- In readStream:
   self.yourNewData = streamReadString(streamId)
   ```

2. **Broadcast changes**:
   ```lua
   if g_server and g_currentMission.missionDynamicInfo.isMultiplayer then
       g_server:broadcastEvent(YourUpdateEvent.new(data))
   end
   ```

---

## Hook System

### How Hooks Work

The mod intercepts FS25 game events using `Utils.appendedFunction`:

```lua
-- Our hook wraps the original FS25 function
SomeClass.someMethod = Utils.appendedFunction(
    SomeClass.someMethod,  -- Original runs first
    function(self, ...)    -- Our code runs AFTER original
        -- Our logic here
    end
)
```

All hooks are tracked in `HookManager` and restored on mod unload via `HookManager:uninstallAll()`.

### Existing Hooks

| Hook | Target | Triggers On | Handler |
|------|--------|-------------|---------|
| Harvest | `FruitUtil.fruitPickupEvent` | Crop harvested | `SoilFertilitySystem:onHarvest()` |
| Fertilizer | `Sprayer.onEndWorkAreaProcessing` | Fertilizer applied | `SoilFertilitySystem:onFertilizerApplied()` |
| Plowing | `Cultivator.processCultivatorArea` | Field plowed | `SoilFertilitySystem:onPlowing()` |
| Ownership | `g_farmlandManager.fieldOwnershipChanged` | Field bought/sold | `SoilFertilitySystem:onFieldOwnershipChanged()` |
| Weather | `g_currentMission.environment.update` | Every frame | `SoilFertilitySystem:onEnvironmentUpdate()` |
| Effect type | `g_effectManager.setEffectTypeInfo` | Effect stored | Remaps custom fill type indices to vanilla |
| Sprayer constant remap | `Sprayer.onEndWorkAreaProcessing` | Sprayer fires | Swaps FillType/SprayType globals for duration of call |

### Adding a New Hook

1. **Add hook installation** in `HookManager.lua`:

```lua
function HookManager:installYourHook()
    if not YourGameClass or not YourGameClass.yourMethod then
        SoilLogger.warning("Could not install your hook — method not found")
        return
    end

    local origMethod = YourGameClass.yourMethod
    YourGameClass.yourMethod = Utils.appendedFunction(
        origMethod,
        function(self, ...)
            if not g_SoilFertilityManager or
               not g_SoilFertilityManager.settings.enabled then
                return
            end

            local ok, err = pcall(function()
                g_SoilFertilityManager.soilSystem:onYourEvent(...)
            end)

            if not ok then
                SoilLogger.warning("Your hook failed: %s", tostring(err))
            end
        end
    )

    self:registerCleanup("YourGameClass.yourMethod", function()
        YourGameClass.yourMethod = origMethod
    end)
    SoilLogger.info("[OK] Your hook installed")
end
```

2. **Call from `installAll()`**:
```lua
function HookManager:installAll(soilSystem)
    -- ... existing hooks
    self:installYourHook()
end
```

3. **Add handler** in `SoilFertilitySystem.lua`:
```lua
function SoilFertilitySystem:onYourEvent(...)
    -- Your logic here
end
```

**Always use `pcall()`** — a crash in our code must never crash the player's game.

---

## HUD System

### Architecture

| File | Role |
|------|------|
| `src/ui/SoilHUD.lua` | Always-on HUD panel — shows current field soil stats, sprayer rate panel, position/theme/font settings |
| `src/ui/SoilReportDialog.lua` | Full-farm paginated soil report (K key) |
| `gui/SoilReportDialog.xml` | Dialog layout — must be included in the zip |

### HUD Visibility Logic

The HUD hides automatically when:
1. Mod disabled (`settings.enabled = false`)
2. Show HUD setting off (`settings.showHUD = false`)
3. J key toggled off (`self.visible = false`)
4. Menu or dialog open (`g_gui:getIsGuiVisible()`)
5. Fullscreen map open

### Render Order Note

FS25 does not expose Z-order APIs for Overlays. Render order is determined by callback registration order. The HUD renders via `FSBaseMission.draw`. If a mod conflict causes overlap, players can move the HUD via the position preset setting.

---

## Testing Your Changes

### Quick Testing Checklist

- [ ] Load mod in clean savegame — no errors in log.txt
- [ ] Harvest crops — nutrients deplete correctly (`SoilFieldInfo <id>`)
- [ ] Apply fertilizer — nutrients restore correctly, spray visuals appear
- [ ] Toggle settings — changes take effect and persist after save/reload
- [ ] Save and reload — all field data and settings survive
- [ ] Multiplayer — server/client sync works (client joins and sees field data immediately)


### Debug Logging

Enable verbose logging in-game: `SoilDebug`

Check `log.txt` (search for `[SoilFertilizer]`) for errors and diagnostic output.

---

## Common Gotchas

### 1. Lua 5.1 Limitations

FS25 uses Lua 5.1 (not 5.2+):

- No `goto` or `continue` — use guard clauses / `if/else`
- No `os.time()` or `os.date()` — use `g_currentMission.time`
- No bitwise operators — use `bitAND`, `bitOR`
- `#` on a hash-keyed table returns undefined behavior — iterate with `pairs()` and count manually

### 2. Global Namespace Pollution

Use module prefixes for global functions:

```lua
-- Bad
function RequestSync() end

-- Good
function SoilNetworkEvents_RequestSync() end
```

### 3. Hook Accumulation

Always register cleanup for every hook you install. Use `self:registerCleanup(name, fn)` in HookManager — it's called automatically on mod unload. Never reinstall a hook without cleaning up the previous one.

### 4. Multiplayer Desyncs

- Always run soil changes on server only (`if g_server then`)
- Always broadcast updates to clients after server-side changes
- Never modify soil data on clients directly

### 5. Custom Fill Type Spray Effects

Vanilla FS25 spray effect code checks `FillType.LIQUIDFERTILIZER` and `SprayType.LIQUIDFERTILIZER` as integer constants. Custom fill types have different indices, so those checks fail silently and no effects appear.

This mod solves it with a three-layer approach in `HookManager:installEffectTypeHook()`:
1. Hook `g_effectManager.setEffectTypeInfo` to remap custom indices to vanilla before effects are stored
2. Inject custom fill types into vanilla `sprayType.fillTypes` arrays so `getIsSprayTypeActive` returns true
3. Wrap `Sprayer.onEndWorkAreaProcessing` with a temporary global table swap — `FillType` and `SprayType` in `getfenv(0)` are replaced with modified copies where the vanilla constant name points to our custom index, then restored immediately after the call

If adding a new custom fill type, add it to the `remap` table in `installEffectTypeHook()`.

### 6. Settings Schema Order Matters

`SettingsSchema.definitions` order determines XML save/load order and network stream order. **Never reorder existing entries after a release** — it breaks saves.

### 7. Translation Keys

All settings need `_short` and `_long` variants for all 26 languages. Multi-option settings also need `_1`, `_2`, etc. option labels.

### 8. Field ID vs Farmland ID

- **Field ID**: Specific field polygon (unique per field)
- **Farmland ID**: Purchasable land parcel (may contain multiple fields)

Use `g_fieldManager:getFieldAtWorldPosition(x, z)` as the primary lookup. Farmland is a fallback only.

### 9. Field ID Resolution in scanFields

When iterating `g_fieldManager.fields`, resolve the actual field ID in priority order:

```lua
local actualFieldId =
    (field.fieldId and field.fieldId > 0 and field.fieldId) or
    (field.id and field.id > 0 and field.id) or
    (field.index and field.index > 0 and field.index) or
    numericLoopKey  -- last resort
```

Using the loop key directly causes data to be stored under the wrong ID on some maps.

---

## Soil Density Map Layers

To enable per-pixel nutrient maps, you must declare the five custom soil nutrient density map layers in your map's `map.xml` file.

### 1. Update map.xml

Find the existing `<densityMaps>` block in your map's `map.xml` and add the following entries:

```xml
<densityMap name="infoLayer_soilN" numChannels="8" createType="8BIT" filename="infoLayer_soilN.grle"/>
<densityMap name="infoLayer_soilP" numChannels="8" createType="8BIT" filename="infoLayer_soilP.grle"/>
<densityMap name="infoLayer_soilK" numChannels="8" createType="8BIT" filename="infoLayer_soilK.grle"/>
<densityMap name="infoLayer_soilPH" numChannels="8" createType="8BIT" filename="infoLayer_soilPH.grle"/>
<densityMap name="infoLayer_soilOM" numChannels="8" createType="8BIT" filename="infoLayer_soilOM.grle"/>
```

### 2. GRLE Setup

On a fresh installation, the GRLE files do not exist yet. `SoilLayerSystem.lua` will gracefully fall back to the fieldData-only path in that case and log a warning.

To create them:
1.  **Launch the game once** with the `map.xml` changes applied.
2.  The Giants Engine will **auto-create placeholder files** in the savegame folder (confirmed FS25 behavior for 8-bit infoLayers declared with `createType="8BIT"`).
3.  Alternatively, copy any existing same-size GRLE from the savegame (e.g., `infoLayer_sprayLevel.grle`) and zero it out with a hex editor. The format is a flat array of 8-bit values when using `8BIT` creation type.

---

## Build & Release

### Build and Deploy

```bash
# Build zip and deploy to FS25 mods folder
py build.py --deploy
```

Check `log.txt` after launching — search for `[SoilFertilizer]` to verify load.

### Preparing a Release

1. **Update version in `modDesc.xml`**
2. **Update version in `DEVELOPMENT.md` header**
3. **Update version in `CLAUDE.md` Project Overview**
4. **Update `CHANGELOG.md`** with all changes since last release
5. **Update `README.md`** version line at the bottom
6. **Build**: `py build.py --deploy`
7. **Test** in singleplayer and multiplayer
8. **Commit** to `development` branch
9. **PR** `development` → `main`
10. **Merge** and create GitHub release with the zip attached

### Release Checklist

- [ ] Version updated in modDesc.xml
- [ ] CHANGELOG.md has an entry for this version
- [ ] Tested in singleplayer (harvest, fertilize, save/load)
- [ ] Tested in multiplayer (client joins, field data arrives)
- [ ] No `[SoilFertilizer ERROR]` lines in log.txt
- [ ] PR targets `main` from `development`

---

**Questions?** Open an issue on GitHub or ask on the [FS25 Modding Community Discord](https://discord.gg/Th2pnq36).
