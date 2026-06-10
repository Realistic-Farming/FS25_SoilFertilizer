<div align="center">

# 🌾 FS25 Soil & Fertilizer
### *Realistic Nutrient Management*

[![Downloads](https://img.shields.io/github/downloads/TheCodingDad-TisonK/FS25_SoilFertilizer/total?style=for-the-badge&logo=github&color=4caf50&logoColor=white)](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/releases)
[![Release](https://img.shields.io/github/v/release/TheCodingDad-TisonK/FS25_SoilFertilizer?style=for-the-badge&logo=tag&color=76c442&logoColor=white)](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/releases/latest)
[![License](https://img.shields.io/badge/license-CC%20BY--NC--ND%204.0-lightgrey?style=for-the-badge&logo=creativecommons&logoColor=white)](https://creativecommons.org/licenses/by-nc-nd/4.0/)
<a href="https://paypal.me/TheCodingDad">
  <img src="https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif" alt="Donate via PayPal" height="50">
</a>

<br>

> *"Applied liquid fertilizer three seasons straight because the yield looked fine. Then I checked the pH — it was sitting at 5.4. The nutrients I'd been pouring in couldn't even be absorbed. One application of lime later and the next harvest told the whole story."*

<br>

**In base FS25, every field is born equal and stays that way forever. This mod remembers.**

Each field builds its own history. Nitrogen drops after a heavy wheat crop. Rain washes potassium out of sandy ground. Fallow fields slowly breathe back to life. The numbers you see in the HUD aren't arbitrary — they're the consequence of every harvest, every storm, and every bag of fertilizer you did or didn't apply.

`Singleplayer` • `Multiplayer (server-authoritative)` • `Persistent saves` • `26 languages`

</div>

> [!WARNING]
> To play the mod at its finest please download the following file.
> https://modsfire.com/X5v9Ytvq7No8flb
> Instructions are inside the README

> [!TIP]
> Want to be part of our community? Share tips, report issues, and chat with other farmers on the **[FS25 Modding Community Discord](https://discord.gg/Th2pnq36)**!

> [!CAUTION]
> **Not compatible with Precision Farming (FS25_precisionFarming).** The mod automatically detects when Precision Farming is active and disables itself to prevent conflicts and data corruption. You must choose one or the other — they cannot run at the same time.


---

## 🆕 What's New in v2.4.1.0

**Fixes:**
- Custom fertilizer piles (MAP, DAP, Urea, AMS, etc.) now load without texture warnings
- Soil data tracked live per-nozzle section during application — no stale values at field edges
- Nozzle sections at field boundaries no longer lose coverage credit
- See & Spray is now a vehicle shop configuration on the JD R700i and R975i — not a runtime toggle key

<details>
<summary>Previous releases</summary>

### v2.4.0.0

**New features:**
- Added JD R700i (28 m) and R975i (36 m) sprayers with per-nozzle section control
- Added tillage work trail (plow/cultivate) visible on HUD and minimap

**Fixes:**
- Variable rate + auto rate no longer double-reduces nutrient gain — 50% rate now delivers 50%, not near-zero
- Spray mist no longer fires when boom is folded or stopped
- Field edge sections now always receive nutrient credit
- HUD always shows field averages, not local cell values
- Ghost bar now correctly applies the Replenishment Rate multiplier
- Yield modifier no longer drops during multi-pass harvest
- Map cell tooltip bars now show numeric values (N/P/K %, pH, OM %)
- P threshold in farm overview corrected (was 45, now 40)
- Minimap overlay anchoring fixed on large maps

**Balancing:**
- Rebalanced pricing across all 20 custom fertilizer types

### v2.2.5.0
- Fixed weed pressure bar oscillating after partial herbicide spray
- Fixed Weeds/Pests/Disease % values misaligned in HUD
- Fixed Precision Farming detection triggering for users with PF disabled in mod manager
- Updated French (fr) translation (community contribution)

### v2.2.4.0 / v2.2.4.1
- Fixed N and K starting at 90%+ on new saves
- Fixed Pass% capping at ~50% after a full-field spray
- Fixed Partial Width mode crediting inactive boom sections
- Fixed variable rate display oscillating with MAP/P-type fertilizers
- Fixed liquid lime draining entire tank instantly

</details>

---

## ✨ Features

### 🧪 Per-Field Soil Chemistry

Five values tracked independently for every field on the map:

| | Nutrient | Role | Depleted By |
|---|---|---|---|
| 🟢 | **Nitrogen (N)** | Growth and leaf mass | Harvest, rain leaching, fall season |
| 🔵 | **Phosphorus (P)** | Root development and energy | Harvest |
| 🟡 | **Potassium (K)** | Water regulation and yield quality | Harvest, rain leaching |
| 🟤 | **Organic Matter (OM)** | Soil structure and nutrient buffering | Builds slowly via manure and plowing |
| ⚗️ | **pH** | Unlocks nutrient availability | Rain acidification — raised by lime and plowing |

All five values persist in your save. A field that's been growing canola for three seasons without lime will feel different from one you've been managing carefully.

### 🌾 Crop-Specific Extraction

Different crops take different amounts from your soil. Push the same field too hard and it shows.

| Crop | N drain | P drain | K drain | Notes |
|---|---|---|---|---|
| 🥔 Potato | ●●●●● | ●●●● | ●●●●● | Extreme K demand — must rotate |
| 🟣 Sugar Beet | ●●●●○ | ●●●○○ | ●●●●● | Heaviest K of any crop |
| 🌻 Sunflower | ●●●●○ | ●●●○○ | ●●●●○ | Moderate-high all round |
| 🌼 Canola | ●●●●○ | ●●●○○ | ●●●●○ | High N demand, oilseed crop |
| 🫘 Soybean | ●●●●● | ●●●○○ | ●●●○○ | Highest N — partial fixation assumed |
| 🌽 Maize | ●●●●○ | ●●●○○ | ●●●●○ | Large biomass, needs N and K |
| 🌾 Wheat | ●●●○○ | ●●○○○ | ●●●○○ | Moderate — manageable with rotation |
| 🌾 Barley / Oats / Rye | ●●●○○ | ●●○○○ | ●●●○○ | Light feeders, good rotation crops |
| 🫛 Peas / Beans | ●●●●○ | ●●●○○ | ●●●●○ | Legumes — still need balanced soil |

### 🔄 Crop Rotation

The mod tracks the last **3 harvested crops** per field and actively rewards good rotation practice — and penalises lazy mono-cropping.

| Situation | Effect |
|---|---|
| **Legume → Non-legume** (soybean, peas, or beans last season) | +0.5 N/day for the first 3 days of spring — nitrogen fixation carry-over |
| **Same crop two seasons running** | ×1.15 extraction multiplier on that harvest — 15% extra depletion across N, P, and K |
| **Healthy alternation** | No modifier in either direction |

The Soil Report now shows your rotation status per field alongside the nutrient recommendations: *Rotation Bonus*, *Fatigue: Same Crop*, or *Rotation: OK*. History is saved with your savegame and synced in multiplayer. Can be toggled off in settings.

### 🐛 Field Health System

Three pressure scores (0–100) track threats to each field independently. Left unchecked they reduce your actual harvest yield — fewer liters in the combine hopper, less money at the sell point. Treat them with the right product and the pressure drops within a few days.

| Pressure | Source | Treatment | Resets naturally | Max penalty |
|----------|--------|-----------|-----------------|-------------|
| 🌿 **Weed** | Grows daily — peaks without tillage | `HERBICIDE` spray | Any tillage / plowing | −30% |
| 🐞 **Pest** | Insects — peaks in summer | `INSECTICIDE` spray | Harvest disperses population | −30% |
| 🍄 **Disease** | Fungal — driven by rain | `FUNGICIDE` spray | 3+ dry days cause natural decay | −25% |

All three are visible in the HUD and the full Soil Report. Each can be toggled off in settings.

### 💊 Fertilizer Types

25+ products tracked, each with a different nutrient job.

**Base game (always available):**

| Fertilizer | N | P | K | Organic Matter | Notes |
|---|---|---|---|---|---|
| **Liquid Fertilizer** | ●●●○○ | ●●○○○ | ●●●○○ | — | Fast-acting, balanced NPK |
| **Solid Fertilizer** | ●●●●○ | ●●●○○ | ●●●○○ | — | Higher N/P, granular |
| **Manure** | ●●○○○ | ●○○○○ | ●●○○○ | ✓ | Slow-release, builds OM over time |
| **Slurry** | ●●●○○ | ●●○○○ | ●●●●○ | ✓ | Liquid organic, K-dominant (real N:P:K ratio) |
| **Digestate** | ●●●○○ | ●●○○○ | ●●●●○ | ✓ | Biogas byproduct, higher N availability than raw manure |
| **Lime** | — | — | — | — | Only raises pH — but nothing else works properly without it |

**Custom liquid fertilizers (purchasable IBC liquid tanks in shop):**

| Product | Type | Primary benefit |
|---|---|---|
| UAN-32 / UAN-28 | Liquid nitrogen | Highest N/L of liquid sources |
| Anhydrous Ammonia | Liquid nitrogen | Maximum N concentration |
| Starter 10-34-0 | Liquid P | In-furrow high-P starter |
| Liquid Urea | Liquid N | Dissolved urea for sprayer application |
| Liquid AMS | Liquid N | Liquid ammonium sulphate |
| Liquid MAP | Liquid P+N | High-P liquid blend |
| Liquid DAP | Liquid P+N | Liquid DAP equivalent |
| Liquid Potash | Liquid K | Dissolved potassium for sprayers |
| Insecticide | Liquid | Pest pressure treatment (sprayer) |
| Fungicide | Liquid | Disease pressure treatment (sprayer) |
| Liquid Lime | Liquid pH agent | Raises pH via sprayer — alternative to dry lime |

**Custom dry/solid fertilizers (purchasable big bags in shop):**

| Product | Type | Primary benefit |
|---|---|---|
| Urea / AMS | Dry nitrogen | Standard granular N sources |
| MAP / DAP | Dry P+N | Phosphorus-focused blends |
| Potash | Dry K | Pure potassium supplement |
| Gypsum | Dry amendment | Lowers pH and improves soil structure |
| Compost | Organic amendment | Best OM builder per application |
| Biosolids | Organic fertilizer | Municipal organic N+P amendment |
| Chicken Manure | Organic fertilizer | Concentrated N+P poultry litter |
| Pelletized Manure | Organic fertilizer | Dense balanced NPK+OM — highest analysis |

**Organic / soil amendments (nutrient profiles):**

| Product | Application | N | P | K | OM | Notes |
|---|---|---|---|---|---|---|
| **Compost** | Spreader | Low | Low | Low | ●●●●● | Best OM builder per litre |
| **Biosolids** | Spreader | ●●○○○ | ●●○○○ | Low | ✓ | Municipal organic amendment |
| **Chicken Manure** | Spreader | ●●●○○ | ●●●○○ | ●●○○○ | ✓ | Concentrated poultry litter |
| **Pelletized Manure** | Spreader | ●●●●○ | ●●●○○ | ●●●●○ | ✓ | Dense balanced organic NPK |
| **Gypsum** | Spreader | — | — | — | Low | Lowers pH, minor OM gain |
| **Liquid Lime** | Sprayer | — | — | — | — | Raises pH via sprayer equipment |

> [!NOTE]
> Organic matter builds slowly — it takes many seasons to accumulate meaningfully. Soil with high OM buffers pH swings and slows nutrient loss from rain.

### 🚜 Soil Compaction

Heavy vehicles compact the soil they drive over. Compaction is tracked per field (0–100%) and
gradually reduces how effectively the field can absorb nutrients.

| Threshold | Vehicle weight | Effect |
|---|---|---|
| **Compaction hit** | ≥ 8 t total (tractor + implement) | +2% compaction per day (once per game day) |
| **Subsoiler pass** | Any cultivator with `isSubsoiler = true` | −15% compaction per pass |
| **Natural decay** | Automatically | −0.5% per game day |

At maximum compaction (100%), the field's nutrient extraction penalty reaches **20%** — compacted
soil binds nutrients and reduces their availability to crops.

The HUD shows compaction as a colour-coded row (green < 20%, amber 20–60%, red > 60%). It also
appears as **overlay layer 10** on the in-game map. Compaction is saved to `soilData.xml` and
synced to all clients in multiplayer. Toggle it in settings if you prefer to skip this mechanic.

### 📊 Coverage Tracking

The sprayer now tracks which individual soil cells have been covered in an application pass.
Coverage fraction is shown live in the HUD as `Coverage: X% / 70% min`. The fully-treated
field notification is gated on achieving **70% minimum coverage** — a single-pass clip across
a field corner no longer triggers a false "field treated" popup.

### 🌦️ Environmental Effects

The mod isn't just about what you put in — it's about what the world takes out.

| Effect | What happens |
|---|---|
| 🌧️ **Rain leaching** | Nitrogen and potassium wash out during heavy rain. Phosphorus binds tightly and barely moves. |
| 🍂 **Fall nitrogen loss** | Biological activity slows in autumn, pulling N levels down naturally. |
| 🌱 **Spring nitrogen boost** | Microbial activity picks back up in spring, recovering a small amount of N. |
| 🌧️ **pH acidification** | Rain is slightly acidic. Ignore liming long enough and your soil will show it. |
| 🌾 **Fallow recovery** | Fields left unplanted for 7+ days slowly recover nutrients on their own. |
| 🚜 **Plowing bonus** | Aerates soil, nudging pH toward neutral and boosting organic matter mixing. |
| 🌿 **Residue incorporation** | Working post-harvest stubble back into the soil releases a small NPK and OM pulse from decomposing straw. Deeper tillage releases more; direct-drills release the least. |

### 🤖 Smart Precision Systems

Three in-vehicle overlay panels that appear when you enter a supported sprayer. Each appears as a collapsible HUD panel that can be independently repositioned in Free Panel Layout mode.

| System | What it does | How to enable |
|---|---|---|
| **Smart Sensor** | Monitors pest, disease, and nutrient need per section. Blocks spraying on sections with no active need detected. | Settings → Admin → Smart Systems. Works with any VWW sprayer. |
| **See & Spray** | Shows live per-cell pressure for pest, disease, and weed at the sprayer's current position. Colour-coded per section. | Purchase a **JD R700i** or **JD R975i** with the *See & Spray* shop configuration selected. |
| **Variable Rate** | Adjusts boom output rate per section based on soil deficits for the loaded product. Green bar = low rate; red bar = high rate. | Bind `SF_VARIABLE_RATE` in **Controls → Mods**. Enable in Admin → Smart Systems. |

Smart Sensor and Variable Rate work with any VWW-capable sprayer. **See & Spray requires the JD R700i (28 m) or JD R975i (36 m)** with the See & Spray option selected at purchase — base game sprayers are not tested with this feature.

**Free Panel Layout** — Enable in Settings → Display → Position, then use the Shift+H edit mode to drag each panel independently. Press **[−]** in any panel's title bar to collapse it to the title bar only. Positions and collapse states are saved to `hud.xml`.

### 📊 Soil HUD

A compact overlay shows the current field's soil status while you're working. Colour-coded indicators make problems visible at a glance:

🟢 **Green** — healthy, no action needed &nbsp;|&nbsp; 🟡 **Amber** — getting low, plan ahead &nbsp;|&nbsp; 🔴 **Red** — depleted, yield is being reduced

The **yield forecast row** (e.g. `Yield ~-18%`) is not just a warning — it reflects what the combine will actually collect. N/P/K deficits, weed, pest, and disease pressure all reduce real harvest liters. The HUD percentage is exactly the hit your tank takes.

Additional rows appear contextually: **Coverage** (`Coverage: X% / 70% min`) while a sprayer is active on a field, and **Compaction** (when soil compaction is above 0% and the setting is enabled). Both are colour-coded with the same green/amber/red tiers as nutrients.

Fully customisable: 5 positions, 4 colour themes, 5 transparency levels, 3 font sizes, and a compact mode that shrinks to one line per nutrient. The drag-to-reposition action (`SF_HUD_DRAG`, default: RMB) is now rebindable through the standard FS25 key bindings menu.

### 📋 Full Farm Soil Report

The **Farm Overview** tab in the Soil PDA page shows all your fields sorted by urgency — the fields that need the most attention appear at the top. Each row shows N/P/K, pH, OM, weed and pest pressure, and an overall status badge. Click any row to open a field detail popup with a complete breakdown, yield forecast, and specific treatment recommendations.

### 📱 Soil PDA Page

Press **`Shift+P`** to open the dedicated Soil & Fertilizer page inside the FS25 in-game menu (PDA). Accessible any time — on foot, in a vehicle, or while paused.

**Left sidebar** — live farm-wide snapshot updated each time the page opens:
- Fields tracked and fields owned
- Average N, P, K, pH, and Organic Matter across all your fields
- Weed, Pest, and Disease pressure field counts
- Fields currently below fertilizer threshold

**Two tabs:**

| Tab | What you see |
|---|---|
| **Farm Overview** | Full list of every tracked field — N%, P%, K%, pH, OM, and an overall status badge. Click any row to open a per-field detail popup |
| **Treatment Plan** | Fields sorted by urgency (worst first) with the primary deficiency or pressure identified. Minor-urgency fields grouped at the bottom |

The interactive **Soil Map overlay** lives in the native PDA Map (ESC → Map). Use the sidebar to select and cycle overlay layers (Nitrogen, Phosphorus, Potassium, pH, OM, Weed, Pest, Disease) without leaving the game map.

**Field Detail popup** (click any row in Farm Overview or Treatment Plan):
- All five nutrient values with colour-coded Good / Fair / Poor status
- Weed, Pest, and Disease pressure — asterisk (`*`) shown when a protection product is active
- Last harvested crop and crop rotation status (Legume Bonus / Fatigue / OK)

---

## ⚙️ Settings

Settings are split across two places.

### ESC → Settings → Game Settings → Soil & Fertilizer

Three core settings live here so you can reach them quickly:

| Setting | Options | What it does |
|---|---|---|
| **Enable mod** | On / Off | Stops all simulation when off |
| **Notifications** | On / Off | Pop-up alerts when fields get critically low |
| **Debug mode** | On / Off | Verbose logging to the game log |

### SHIFT+O — Full Settings Panel

Press **`Shift+O`** anywhere in-game (on foot or in a vehicle) to open the full settings panel. Settings are organised into three categories. The panel also includes an **Admin** button (previously labelled *Drain Vehicle*) — pressing it opens a dedicated admin page with all console commands listed and executable as buttons directly in-game:

**🌱 Simulation** — controls the core simulation behaviour

| Setting | Options | What it does |
|---|---|---|
| **Fertility system** | On / Off | Toggles the entire nutrient and pH simulation |
| **Nutrient cycles** | On / Off | Enables crop depletion and natural recovery |
| **Fertilizer costs** | On / Off | Adds running costs to fertilizer application |
| **Seasonal effects** | On / Off | Spring nitrogen boost and fall nitrogen loss |
| **Rain effects** | On / Off | Leaching and pH acidification from rain |
| **Plowing bonus** | On / Off | Whether plowing improves OM and pH |
| **Residue incorporation** | On / Off | Whether tillage tools release nutrients from worked-in straw residue |
| **Weed pressure** | On / Off | Track weed competition per field |
| **Pest pressure** | On / Off | Track insect pest populations per field |
| **Disease pressure** | On / Off | Track crop disease per field |
| **Crop rotation** | On / Off | Enable legume bonus and mono-crop fatigue multiplier |
| **Soil compaction** | On / Off | Heavy vehicles (≥ 8 t) compact soil, reducing nutrient availability |
| **Imperial units** | On / Off | Sprayer rates in gal/ac and lb/ac instead of L/ha and kg/ha |
| **Difficulty** | Simple / Realistic / Hardcore | Scales depletion rate — 0.7× / 1× / 1.5× |

**🖥️ Display / HUD** — controls what you see on screen

| Setting | Options | What it does |
|---|---|---|
| **HUD enabled** | On / Off | Show or hide the soil overlay |
| **HUD position** | 6 options | Top-right, top-left, bottom-right, bottom-left, centre-right, or custom |
| **HUD colour theme** | 4 themes | Green / Blue / Amber / Mono |
| **HUD transparency** | Clear → Solid | 5 opacity levels |
| **HUD font size** | Small / Medium / Large | Scales all HUD text |
| **Auto rate control** | On / Off | Sprayer rate auto-adjusts toward the target rate for the current product |

**🗺️ Map** — controls the PDA map overlay

| Setting | Options | What it does |
|---|---|---|
| **Active map layer** | Off / N / P / K / pH / OM / Urgency / Weed / Pest / Disease / Compaction | Nutrient layer shown on the PDA map |
| **Overlay density** | Low / Medium / High | Number of data points rendered on the map overlay — Low (8k), Medium (20k), High (40k). Reduce if the map causes frame drops |

> [!NOTE]
> In multiplayer, settings are **server-authoritative** — the host's settings are pushed to all clients on join. Non-admin clients can see but not change server settings. HUD display preferences are always local and can be changed by any player.

---

## 🖥️ Console Commands

Open the developer console with **`~`** and type `soilfertility` for the full list, or press **`Shift+O`** → **Admin** to access all commands as buttons directly in-game.

| Command | Arguments | Description |
|---|---|---|
| `SoilEnable` / `SoilDisable` | — | Toggle the mod on or off |
| `SoilSetDifficulty` | `1` `2` `3` | Simple / Realistic / Hardcore |
| `SoilSetFertility` | `true` / `false` | Toggle fertility simulation |
| `SoilSetNutrients` | `true` / `false` | Toggle nutrient cycles |
| `SoilSetFertilizerCosts` | `true` / `false` | Toggle fertilizer costs |
| `SoilSetNotifications` | `true` / `false` | Toggle alert popups |
| `SoilSetSeasonalEffects` | `true` / `false` | Toggle seasonal N changes |
| `SoilSetRainEffects` | `true` / `false` | Toggle rain leaching and acidification |
| `SoilSetPlowingBonus` | `true` / `false` | Toggle plowing OM/pH bonus |
| `SoilDrainVehicle` | — | Drain custom fill types from vehicle + implements (50% refund) |
| `SoilFieldInfo` | `<fieldId>` | Detailed soil readout for one field |
| `SoilFieldForecast` | `<fieldId>` | Yield forecast and treatment recommendations for one field |
| `SoilListFields` | — | List all tracked fields with current soil values |
| `SoilShowSettings` | — | Print current settings to log |
| `SoilResetSettings` | — | Reset everything to defaults |
| `SoilSaveData` | — | Force-save soil state now |
| `SoilDebug` | — | Toggle verbose debug logging |

---

## 🔌 Mod Integrations

All integrations are detected automatically at runtime and fail gracefully if the mod isn't installed.

| Mod | Behaviour |
|---|---|
| **FS25_precisionFarming** | **Incompatible.** When Precision Farming is detected as active, this mod automatically disables itself at startup to prevent data corruption. Disable PF in the mod manager to use this mod instead. |
| **FS25_SeasonalCropStress** | Soil pH and organic matter influence evapotranspiration rates per field. |
| **FS25_NPCFavor** | NPC neighbour favour quests can reference your fields' soil state. |
| **FS25_MoistureSystem** | Compatible — both mods use independent hooks. No conflicts. |

---

## 🛠️ Installation

**1. Download** `FS25_SoilFertilizer.zip` from the [latest release](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/releases/latest).

**2. Copy** the ZIP (do not extract) to your mods folder:

| Platform | Path |
|---|---|
| 🪟 Windows | `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\` |
| 🍎 macOS | `~/Library/Application Support/FarmingSimulator2025/mods/` |

**3. Enable** *Realistic Soil & Fertilizer* in the in-game mod manager.

**4. Load** any career save — soil data initialises automatically on first load.

---

## 🎮 Quick Start

```
1. Load your farm — the soil HUD appears in the top-right corner
2. Drive to any field — nutrient values update as you move
3. Amber or red values → that field needs fertilizer or lime
4. Apply lime first — it unlocks the full value of everything else
5. Apply fertilizer → watch N/P/K climb in real time
6. Open the tablet → Soil & Fertilizer → Farm Overview to see all fields by urgency
7. Press Shift+O → open the full settings panel to tune the simulation
8. Let a field go fallow for a season → it slowly recovers on its own
9. At harvest → healthy soil means the full yield you worked for
```

> [!TIP]
> Fields start slightly acidic and with moderate nutrients — matching the base game's starting state. Lime first, then fertilize. Nutrients in acidic soil have reduced availability no matter how much product you apply.

---

## ⚠️ Known Limitations

| Issue | Details |
|---|---|
| 🌱 **Base game lime indicator** | The base game's "needs liming" flag is a separate system from our pH tracking. Both update when you apply lime through the sprayer, but the indicators can show different states until the field is treated. Workaround: disable the base game's liming requirement in **Settings → Farming → Liming** to rely solely on our HUD. |
| 🌐 **Multiplayer** | Soil simulation runs on the server only. Clients receive synced state on join and after each harvest or fertiliser event. |
| ⚠️ **Section Control** | When outer boom sections are shut off at field boundaries, nutrient credit scales to the active fraction. Sections manually blocked by a Section Control mod may not be detected — credit is based on the sprayer's reported active sections, not physical coverage. |

---

## 🤝 Contributing

Found a bug? [Open an issue](https://github.com/TheCodingDad-TisonK/FS25_SoilFertilizer/issues/new/choose) — the template will walk you through what to include.

Want to contribute code? PRs are welcome on the `development` branch. See `CLAUDE.md` in the repo root for architecture notes and naming conventions.

---

## 📝 License

This mod is licensed under **[CC BY-NC-ND 4.0](https://creativecommons.org/licenses/by-nc-nd/4.0/)**.

You may share it in its original form with attribution. You may not sell it, modify and redistribute it, or reupload it under a different name or authorship. Contributions via pull request are explicitly permitted and encouraged.

**Author:** TisonK &nbsp;·&nbsp; **Version:** 2.4.1.2

© 2026 TisonK — See [LICENSE](LICENSE) for full terms.

---

<div align="center">

*Farming Simulator 25 is published by GIANTS Software. This is an independent fan creation, not affiliated with or endorsed by GIANTS Software.*

*Your soil remembers everything.* 🌱

</div>
