-- MAINT-79-door_host_env.lua - NOT A TEST (no _test suffix). Loaded before the Esc door
-- page by MAINT-79-door_l10n_gate_test.lua so the page's file-level MOD_NAME
-- (RfPdaMenuPage.lua:17, SeasonalCropStressModName or g_currentModName) resolves to a
-- NON-Soil host, as it does in-game when DairyCore's copy of the door is the one loaded
-- (the engine sets g_currentModName while it sources a mod's files).
g_currentModName = "FS25_DairyCore"
