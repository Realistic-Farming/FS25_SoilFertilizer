# FS25_SoilFertilizer self-test suite

Offline checks that run on Node.js (no game, no admin, no Lua install). The whole
`tools/` directory is excluded from the mod zip by `build.py`, so none of this ships.

## Run it

```bash
bash tools/test/run.sh            # syntax + lint + logic tests (installs deps on first run)
# or, from tools/test/:
npm install                       # once
npm run all                       # everything
npm run syntax                    # Lua 5.1 parse check only
npm run lint                      # FS25 footgun lint only
npm test                          # logic tests only
```

Each command exits non-zero on failure, so it's CI/pre-commit friendly.

## Wire it into your workflow

- **Validation suite:** `tools/run_all_checks.bat` runs the PowerShell static analysis *and* this suite, then summarises both.
- **Git pre-commit hook (opt-in):** `bash tools/test/install-hooks.sh` installs a hook that runs `npm run check` (syntax + lint) whenever a `.lua` file is staged. Skip once with `git commit --no-verify`; remove with `rm "$(git rev-parse --git-path hooks)/pre-commit"`.

## What it covers

| Layer | Tool | Catches |
|-------|------|---------|
| **Syntax** | `syntax-check.mjs` (`luaparse`, pinned to Lua 5.1) | Parse errors and 5.2+-only constructs (`goto`, `::labels::`) that make the mod fail to load in-game with no message. Runs over every `src/**/*.lua`. |
| **Lint** | `lint.mjs` | FS25-sandbox footguns that *parse* fine but break at runtime — `os.time` / `os.date` / `os.clock`, etc. (see CLAUDE.md "What DOESN'T Work"). |
| **Logic** | `run-tests.mjs` (`fengari` Lua VM) | Behavioural regressions in pure logic — coverage math, fertilizer profiles, nutrient/burn formulas — by loading the real `src` modules against a mocked FS25 environment and asserting. |

## Writing a logic test

Add `tools/test/lua/<name>_test.lua`. Declare which real source files to load with a
header comment, then assert with the `T` helpers:

```lua
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilFertilitySystem.lua

local sys = setmetatable({ fieldData = { [1] = { fieldArea = 2.0 } } },
                         { __index = SoilFertilitySystem })
sys:trackSprayerCoverage(1, 100, "FERTILIZER", true)
T.ok("coverage advanced", sys.fieldData[1].sessionCoverageFraction > 0)
```

`T.ok(name, cond)`, `T.eq(name, got, want)`, `T.near(name, got, want, tol)`.

The runner builds one Lua program — `prelude.lua` (engine mock + `T` framework) + the
declared `src` files + your test — and runs it in a fresh fengari state. Load order
matters: declare deps in the same order `src/main.lua` loads them (Logger → Constants →
systems). Construct `self` with `setmetatable({…}, { __index = SoilFertilitySystem })`
and call methods directly so you skip `.new()` (which pulls in the live game). Extend
`prelude.lua` when a function under test reaches for more of the engine.

## Limits (the "1/10" that still needs a human)

Rendering/HUD layout, real density-map C++ calls, multiplayer-over-the-wire sync, and
GIANTS-engine behaviour can't run here — those still need an in-game test. fengari is
Lua 5.3, so the *syntax* gate is the authoritative 5.1 check; logic tests target
dialect-agnostic math.
