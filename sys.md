# FS25 Soil Fertilizer - 3 Systems Quick Reference

## System Overview

```
┌─────────────────────────────────────────────────────────────┐
│  YOUR MOD: Three Integrated Precision Farming Systems       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────┐ │
│  │  SEE & SPRAY     │  │  SMART SENSOR    │  │  VAR RATE│ │
│  │  (System 1)      │  │  (System 2)      │  │  (Sys 3) │ │
│  ├──────────────────┤  ├──────────────────┤  ├──────────┤ │
│  │ Real-time weed   │  │ Soil condition   │  │ Map-driv │ │
│  │ detection per    │  │ monitoring with  │  │ en spray │ │
│  │ nozzle           │  │ multi-layer      │  │ rate adj │ │
│  │                  │  │ density sampling │  │ ustment  │ │
│  │ FIRES: nozzles   │  │                  │  │          │ │
│  │ when weed state  │  │ SHOWS: PH,       │  │ ADJUSTS: │ │
│  │ detected         │  │ nutrients,       │  │ % spray  │ │
│  │                  │  │ moisture         │  │ rate     │ │
│  └──────────────────┘  └──────────────────┘  └──────────┘ │
│         │                    │                     │        │
│         └────────┬───────────┴──────────┬──────────┘        │
│                  │                      │                   │
│      All access DENSITY MAPS via getDensityAtWorldPos()    │
│      All check SPRAYER state via getIsTurnedOn()           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## System 1: See & Spray (Spot Spraying)

### What Giants API Provides

```
WeedSpotSpray Specialization (FS22 standard, FS25 compatible)
├── Per-nozzle effect management
├── Density map weed detection
├── Nozzle state machine (OFF → TURNING_ON → ON → TURNING_OFF)
└── Fade animation shader parameters
```

### Code Pattern You Use

```lua
-- STEP 1: Read weed density at vehicle's current position
local weedMapId, weedFirstCh, weedNumCh = 
    g_currentMission.weedSystem:getDensityMapData()
local densityBits = getDensityAtWorldPos(weedMapId, x, y, z)
local weedState = bitAND(bitShiftRight(densityBits, weedFirstCh), 
                         2 ^ weedNumCh - 1)

-- STEP 2: If weed detected, mark nozzle as active
if spec.weedDetectionStates[weedState] then
    nozzleNode.lastActiveTime = g_time
    spec.effectsDirty = true
end

-- STEP 3: Update nozzle visual effect (fade in/out)
if nozzleNode.lastIsActive ~= nozzleNode.isActive then
    effect.state = ShaderPlaneEffect.STATE_TURNING_ON  -- or OFF
    effect.fadeDir = {1, 0}  -- direction of fade
end

-- STEP 4: Animate fade progress over effectFadeTime (0.25s)
effect.fadeCur[1] = effect.fadeCur[1] + effect.fadeDir[1] * (dt / 0.25)
setShaderParameter(effect.node, "fadeProgress", effect.fadeCur[1], ...)
```

### Your Implementation Files

- **Panel UI:** `src/ui/SoilSeeAndSprayPanel.lua`
  - Displays real-time nozzle status (RED = firing, GRAY = idle)
  - Shows weed pressure per grid cell

- **Manager:** Built into `src/SoilFertilitySystem.lua`
  - Reads weed density each frame
  - Tracks nozzle lastActiveTime
  - Updates effect states

### Integration with Sprayer

```lua
-- Override this function to suppress default sprayer effects:
function WeedSpotSpray:getAreEffectsVisible(superFunc)
    if self.spec_weedSpotSpray.isAvailable then
        return false  -- ← Hide default effects, use custom nozzle effects
    end
    return superFunc(self)
end
```

**Why:** With See & Spray, you don't want the **entire sprayer effect visible**. 
Instead, only individual **nozzles' effects show** where they actually detect weeds.

---

## System 2: Smart Sensor (Soil Monitoring)

### What Giants API Provides

```
Terrain Detail Density Maps (FS25)
├── Weed state (4 bits)
├── Spray type (3 bits)
├── Soil pH (4-5 bits)
├── Organic matter (5 bits)
├── Nutrient N/P/K (8 bits each)
├── Ground type - clay/loam/sand (3 bits)
└── Soil moisture (5 bits)

Access via: g_currentMission.fieldGroundSystem:getDensityMapData(LayerType)
```

### Code Pattern You Use

```lua
-- STEP 1: Get map metadata
local soilPHMapId, phFirstCh, phNumCh = 
    g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.SOIL_PH)

-- STEP 2: Sample at current position
local x, y, z = getWorldTranslation(vehicle:getRootNode())
local densityBits = getDensityAtWorldPos(soilPHMapId, x, y, z)

-- STEP 3: Extract value using bitwise magic
local phValue = bitAND(bitShiftRight(densityBits, phFirstCh), 2 ^ phNumCh - 1)

-- STEP 4: Decode to human-readable (0-15 bits → 4.0-9.0 pH)
local actualPH = 4.0 + (phValue / 15) * 5.0  -- linear scale
```

### Your Implementation Files

- **Panel UI:** `src/ui/SoilSmartSensorPanel.lua`
  - Displays soil PH, nutrients, moisture in real-time
  - Color-coded readiness indicators

- **Manager:** `src/SoilSensorManager.lua`
  - Samples all density maps at 1 Hz (once per second)
  - Maintains moving average to smooth jitter
  - Logs data for trend analysis

### Key Function: Bitwise Extraction

```lua
function SoilSensorManager:readDensity(mapType, x, y, z)
    local mapData = self.densityMaps[mapType]
    local bits = getDensityAtWorldPos(mapData.id, x, y, z)
    
    -- Extract value at specific bit range
    return bitAND(
        bitShiftRight(bits, mapData.firstChannel),
        2 ^ mapData.numChannels - 1
    )
end
```

**Critical:** Each nutrient occupies a specific number of bits. If you read `firstChannel=10, numChannels=8`, you're reading bits 10-17. If another nutrient uses bits 18-22, reading past channel 17 gives you the wrong data!

---

## System 3: Variable Rate (Spray Adjustment)

### What Giants API Provides

```
Sprayer Specialization Hooks
├── getSprayerUsage(fillType, dt)  ← Override this!
├── Extended Sprayer with variable work width sections
└── Section control integration

Usage formula: usage = scale × litersPerSecond × speedLimit × workWidth × dt × 0.001
Your multiply: usage = usage × variableRateMultiplier
```

### Code Pattern You Use

```lua
-- STEP 1: Override getSprayerUsage()
function MyVariableRate:getSprayerUsage(superFunc, fillType, dt)
    local baseUsage = superFunc(self, fillType, dt)
    
    -- STEP 2: Read soil condition map
    local nutrientValue = self:getDensityValue("nitrogen", x, y, z)
    
    -- STEP 3: Calculate optimal rate (0.5 = 50%, 2.0 = 200%)
    local multiplier = 1.0
    if nutrientValue > 200 then
        multiplier = 0.5  -- High N, spray less
    elseif nutrientValue < 100 then
        multiplier = 1.5  -- Low N, spray more
    end
    
    -- STEP 4: Return adjusted usage
    return baseUsage * multiplier
end
```

### Your Implementation Files

- **Panel UI:** `src/ui/SoilVariableRatePanel.lua`
  - Shows current rate multiplier (50%, 75%, 100%, 150%, 200%)
  - Graph of spray rate vs. soil nutrient level

- **Manager:** `src/SprayerRateManager.lua`
  - Reads nutrient density map
  - Calculates optimal rate per section
  - Hooks into Sprayer usage calculation

### Integration with Variable Work Width

```lua
-- If you also have variable work width specialization:
if self.spec_variableWorkWidth then
    local sections = self.spec_variableWorkWidth.sections
    
    for i = 1, #sections do
        local section = sections[i]
        
        -- Option A: Adjust rate while section is active
        local mult = self:getRateForSection(i)
        
        -- Option B: Disable low-spray sections entirely
        if mult < 0.1 then
            section.isActive = false  -- Turn off this nozzle section
        end
    end
end
```

---

## Density Map Layer Cheat Sheet

### Common Layers & Bit Layouts

```
WEED_STATE
├─ Bits: 4
├─ Range: 0-15 (16 states)
├─ Meaning: Weed pressure level
├─ Usage: See & Spray detection
└─ Example: 0=none, 8=medium, 15=heavy

SOIL_PH
├─ Bits: 5
├─ Range: 0-31 → map to 4.0-9.0
├─ Meaning: Soil acidity
├─ Usage: Smart Sensor display, lime application
└─ Formula: pH = 4.0 + (value/31)*5.0

NUTRIENT_N
├─ Bits: 8
├─ Range: 0-255 (ppm equivalent)
├─ Meaning: Available nitrogen
├─ Usage: Var-rate N application
└─ Encoding: 0-255 usually maps to 0-250 ppm

ORGANIC_MATTER
├─ Bits: 5
├─ Range: 0-31 (%)
├─ Meaning: Soil organic content
├─ Usage: Fertility assessment
└─ Formula: % = (value/31)*100

GROUND_TYPE
├─ Bits: 3
├─ Range: 0-7 (texture class)
├─ Meaning: Clay(0) → Loam(3) → Sand(6)
├─ Usage: Water holding capacity, compaction
└─ Affects: Spray drift, penetration
```

### How to Read a New Layer

1. **Ask Giants API:**
   ```lua
   local mapId, ch, chCount = 
       g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.YOUR_LAYER)
   ```

2. **Sample once:**
   ```lua
   local bits = getDensityAtWorldPos(mapId, x, y, z)
   ```

3. **Extract:**
   ```lua
   local value = bitAND(bitShiftRight(bits, ch), 2^chCount - 1)
   ```

4. **Decode if needed:**
   ```lua
   if chCount == 8 then
       -- 0-255 range, maybe map to 0-250 ppm
       local ppm = (value / 255) * 250
   elseif chCount == 5 then
       -- 0-31 range, maybe map to 0-100%
       local percent = (value / 31) * 100
   end
   ```

---

## State Machine Diagram: See & Spray Effects

```
                    nozzle.isActive becomes TRUE
                              │
                              ↓
    ┌──────────┐      ┌──────────────────┐
    │   OFF    │      │  TURNING_ON      │
    │ (hidden) │      │  (fading in)     │
    └──────────┘      └──────────────────┘
         ↑                     │
         │                     │
         │          effectFadeTime = 0.25s
         │                     │
         │         fadeCur[1] goes -1 → +1
         │                     │
         │                     ↓
         │              ┌──────────┐
         │              │    ON    │
         │              │ (visible)│
         │              └──────────┘
         │                     │
         │        nozzle.isActive becomes FALSE
         │                     │
         │          ┌──────────────────┐
         │          │  TURNING_OFF     │
         │          │  (fading out)    │
         │          └──────────────────┘
         │                     │
         │         effectFadeTime = 0.25s
         │                     │
         │         fadeCur[1] goes +1 → -1
         │                     │
         └─────────────────────┘

Key Variables:
- effect.state = ShaderPlaneEffect.STATE_*
- effect.fadeCur[1] = progress (-1 to +1)
- effect.fadeDir[1] = direction (+1 or -1)
- setShaderParameter(effect.node, "fadeProgress", fadeCur[1], ...)
```

---

## Network Events Checklist

For multiplayer, synchronize these:

```lua
✓ See & Spray: Nozzle firing state
  └─ When: nozzle.isActive changes
  └─ Send: {vehicleId, nozzleIndex, isActive}
  
✓ Smart Sensor: Field sample readings
  └─ When: Moving to new field cell
  └─ Send: {vehicleId, fieldId, pH, N, P, K}
  └─ Note: High frequency! Consider throttling to 1 Hz
  
✓ Variable Rate: Rate multiplier changes
  └─ When: User adjusts rate or field zone changes
  └─ Send: {vehicleId, rateMultiplier}
  └─ Sync: All clients must use same multiplier
```

---

## Performance Tips

### 1. Cache Density Map IDs

```lua
-- BAD: Call every frame
for i = 1, 100 do
    local mapId = g_currentMission.fieldGroundSystem:getDensityMapData(...)
end

-- GOOD: Cache once on init
self.weedMapId, self.weedFirstCh, self.weedNumCh = 
    g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.WEED_STATE)
```

### 2. Throttle Density Reads

```lua
-- Expensive: Every frame
if self.readCounter % 60 == 0 then  -- Every 60 frames = ~1 Hz at 60 FPS
    local weed = getDensityAtWorldPos(self.weedMapId, x, y, z)
end
self.readCounter = self.readCounter + 1
```

### 3. Batch Multiple Reads at Same Position

```lua
-- BAD: 5 separate queries
local weed = getDensityAtWorldPos(weedMapId, x, y, z)
local ph = getDensityAtWorldPos(phMapId, x, y, z)
local n = getDensityAtWorldPos(nMapId, x, y, z)
-- ... etc

-- GOOD: Sample all at once (slight engine optimization)
local x, y, z = getWorldTranslation(node)
local weed = getDensityAtWorldPos(weedMapId, x, y, z)
local ph = getDensityAtWorldPos(phMapId, x, y, z)
-- Engine caches recently queried chunks
```

### 4. Use Simplified UI During Gameplay

```lua
-- Show full sensor data only in menu
if g_currentMission.paused then
    self:renderDetailedSensorData()
else
    self:renderSimplifiedHUD()  -- Just PH color, not all values
end
```

---

## Troubleshooting

### Problem: Nozzles fire when they shouldn't

```lua
-- CHECK: Density bits are being extracted correctly
local bits = getDensityAtWorldPos(weedMapId, x, y, z)
print(string.format("Raw bits: %d", bits))

-- Manually extract:
local manual = bitAND(bitShiftRight(bits, weedFirstCh), 2^weedNumCh - 1)
print(string.format("Weed value: %d (ch=%d, num=%d)", 
    manual, weedFirstCh, weedNumCh))

-- ISSUE: If manual value is always 0 or always 15, check:
-- 1. Are you reading the RIGHT mapId?
-- 2. Is the map generated for this field?
-- 3. Are x, y, z in the correct coordinate space?
```

### Problem: "getAreEffectsVisible not found"

```lua
-- You're trying to override WeedSpotSpray but it's not loaded
-- CHECK: modDesc.xml includes WeedSpotSpray specialization
-- ADD to your vehicle spec initialization:
if SpecializationUtil.hasSpecialization(WeedSpotSpray, vehicleType.specializations) then
    -- Hook it
end
```

### Problem: Variable rate doesn't sync multiplayer

```lua
-- Network event not sent properly
-- CHECKLIST:
-- 1. Event:sendToServer() called? (not just sendToClient)
-- 2. Event:run() implemented with connection parameter?
-- 3. Server broadcasts back: g_server:broadcastEvent(self)?
-- 4. Client handler registered?

if g_server ~= nil then
    self:run(g_connection)
else
    g_client:getServerConnection():sendEvent(self)
end
```

---

## Reference: Giants Classes Used

```
Class                          Purpose
─────────────────────────────────────────────────────
WeedSpotSpray                  Per-nozzle effect control
Sprayer                        Base spray functionality
ExtendedSprayer                Variable work width
ShaderPlaneEffect              Spray particle visuals
FieldDensityMap                Terrain detail layers
NetworkEvent                   Multiplayer sync
DensityMapHeightType           Soil layer definitions
```

---