## What Does This PR Do?

<!-- One paragraph summary. What changed and why? -->

## Related Issue

<!-- Closes #, Fixes #, or "no issue" -->

## Type of Change

- [ ] Bug fix
- [ ] New feature (crop, fertilizer, setting, UI)
- [ ] Refactor / code quality
- [ ] Documentation / translations
- [ ] Build / tooling

## How Was This Tested?

- [ ] Singleplayer - loaded a savegame, no errors in log.txt
- [ ] Multiplayer - tested as host and/or client

- [ ] Relevant console commands ran (`SoilFieldInfo`, `SoilShowSettings`, etc.)

<!-- Describe what specifically you tested and any edge cases you checked -->

## Checklist

- [ ] I read `DEVELOPMENT.md` before writing code
- [ ] I targeted the `development` branch (not `main`)
- [ ] My change touches only what it needs to - no unrelated edits
- [ ] If I added a setting: one entry in `SettingsSchema.lua` + `_short`/`_long` translations in `modDesc.xml` for all 10 languages
- [ ] If I changed crop/fertilizer values: they're in `Constants.lua`, not hardcoded
- [ ] If I changed behaviour: `CHANGELOG.md` has an entry under the correct version
- [ ] No `assert()` calls - errors are handled gracefully with `pcall()`
- [ ] No Lua 5.2+ syntax (`goto`, `continue`, `os.time()`, etc.)

## Screenshots / Log Output (if relevant)

<!-- Paste a log excerpt or screenshot if this fixes a visible bug or changes UI -->
