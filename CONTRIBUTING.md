# Contributing to FS25_SoilFertilizer

Thanks for your interest in contributing! This mod has a specific architecture — please read this guide before opening a PR so your time isn't wasted.

---

## Before You Start

**Talk to us first.** Open a GitHub issue before writing code. This prevents duplicate effort and makes sure the change fits the mod's direction.

**Read the docs.** The key files are:

| File | What it covers |
|------|----------------|
| `DEVELOPMENT.md` | Architecture, adding crops/fertilizers/settings, hook system, build process |
| `CLAUDE.md` | Naming conventions, module loading order, FS25 Lua constraints, what doesn't work |
| `CHANGELOG.md` | What changed and when |

If you skip these and submit a PR that adds a setting without updating `SettingsSchema.lua`, or uses `goto` in Lua 5.1, the review will just send you back.

> [!WARNING]
> **This mod is NOT compatible with Precision Farming (FS25_precisionFarming).** The mod auto-detects PF and disables itself when PF is enabled. Do NOT submit PRs attempting to add PF compatibility — this is a permanent architectural decision. Players must choose one or the other. If PF is installed but disabled in the mod manager, our mod will run normally.

---

## Architecture in a Nutshell

FS25_SoilFertilizer has a **schema-driven settings system**. One entry in `src/config/SettingsSchema.lua` auto-generates the UI, XML save/load, network sync, and console commands. If you're adding a setting, you touch one file — not five.

Key files to understand before changing anything significant:

```
src/config/Constants.lua        — all tunable values (thresholds, extraction rates, etc.)
src/config/SettingsSchema.lua   — single source of truth for settings
src/SoilFertilitySystem.lua     — core simulation logic
src/hooks/HookManager.lua       — how the mod intercepts FS25 game events
src/ui/SoilHUD.lua              — always-on legend HUD
src/ui/SoilReportDialog.lua     — full soil report dialog (K key)
gui/SoilReportDialog.xml        — dialog layout (must be included in zip via build.py)
```

---

## FS25 Lua Constraints

FS25 runs **Lua 5.1**. This is non-negotiable — the engine sandbox enforces it.

| Not available | Use instead |
|---|---|
| `goto` / `continue` | Guard clauses / `if/else` |
| `os.time()` / `os.date()` | `g_currentMission.time` / `.environment.currentDay` |
| Slider widgets | `MultiTextOption` or quick buttons |
| `DialogElement` base | `MessageDialog` pattern |

Wrap anything that could fail in `pcall()`. Don't let hook errors propagate to the base game.

---

## Code Standards

**Do:**
- Follow the naming conventions in `CLAUDE.md` (PascalCase classes, camelCase methods, UPPER_SNAKE_CASE constants)
- Add crop extraction rates to `Constants.lua` — the system picks them up automatically, no other code needed
- Add new settings through `SettingsSchema.lua` only — don't hand-write UI, save/load, or sync code
- Wrap hook logic in `pcall()` — a crash in our code should never crash the player's game
- Test in multiplayer if your change touches soil data, settings sync, or network events
- Update `CHANGELOG.md` with a clear entry under the correct version

**Don't:**
- Submit a PR that rewrites files you weren't asked to touch
- Reorder existing entries in `SettingsSchema.definitions` — this breaks saves
- Add a setting without its `_short` and `_long` translation keys in `modDesc.xml` (all 26 languages)
- Commit the `.zip` directly — use `py build.py --deploy` and let the release process handle it
- Use `assert()` — use graceful error handling with user-facing dialogs instead

---

## Pull Request Process

1. **Branch from `development`**, not `main`. Target branch for your PR is always `development`.
2. **One change per PR.** A bug fix and an unrelated refactor are two PRs.
3. **Test in-game.** Check `log.txt` for `[SoilFertilizer]` errors. Include what you tested in the PR description.
4. **Update the docs** if behavior changes — at minimum, `CHANGELOG.md`.
5. **PR description should answer:**
   - What does this change?
   - Why is it needed?
   - How did you test it? (singleplayer / multiplayer?)
   - Related issue number, if any

Maintainers merge development → main on a release cycle, not per-PR.

---

## What We're Looking For

- **Bug fixes** — always welcome, especially with a log excerpt showing the error
- **New crop support** — add extraction rates to `Constants.lua` (see `DEVELOPMENT.md`)
- **Translations** — all 26 languages in `modDesc.xml` under `<l10n>`
- **Performance** — the update loop runs every 30s, hooks run on every harvest/spray event
- **UI/UX improvements** — for the Soil Report dialog or HUD legend

---

## Bug Reports

Good bug reports save everyone time. Please include:

```
**Version**: [e.g. 1.0.7.0 — check modDesc.xml or the mod menu]
**Singleplayer or Multiplayer**: [SP / MP Host / MP Client]
**Difficulty**: [Simple / Realistic / Hardcore]
**Other mods**: [Paste the list or note if it's a clean mod set]

**What happened**:

**What you expected**:

**Field ID** (if relevant): [use SoilFieldInfo <id> in the dev console]

**Log excerpt** (search log.txt for [SoilFertilizer]):
```

The developer console is opened with `~`. Type `soilfertility` for a list of diagnostic commands. `SoilDebug` enables verbose logging.

---

## Recognition

Contributors are credited in `CHANGELOG.md` per version and in the git history.

---

**Questions?** Open a GitHub issue or Discussion — we're happy to help you get oriented before you dive in.
