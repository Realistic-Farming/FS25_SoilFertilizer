# Gemini - Start Here

This repo is part of the **Realistic-Farming** ecosystem. Before you implement, write, or change anything here, follow these rules. They are binding, the same way your own system instructions are.

## Must follow

1. **Read the shared ledger first.** The full protocol and the running Claude and Gemini ledger live in the `ecosystem-dev-tracking` workspace (`CLAUDE-GEMINI-LOG.md`, plus `ecosystem-map.md` for how the mods wire together, and `MEMORY.md` for where things stand right now). Read them before starting, and append a dated entry when you finish.
2. **Writing voice: no em dashes, ever.** Plain human voice. Use a hyphen, a comma, parentheses, or split the sentence. Applies to commits, PRs, releases, docs, code comments, and in-game text. Scan before you ship.
3. **No branding, no AI attribution.** Never add "Generated with...", "Co-Authored-By:", or any AI or vendor links anywhere.
4. **Git discipline.** Work on the `development` branch. Never commit or push directly to `main` or `master`. The stable branch moves only via PR.
5. **No guessing the FS25 API.** Verify against the SDK source, the Community LUADOC, and the lua-scripting references. If you cannot reach them, say so and ask. Do not guess a signature and present it as verified.
6. **Ship all 26 languages** from day one for any new string: en de fr nl it pl es ea pt br ru uk cz hu ro tr fi no sv da kr jp ct fc id vi.
7. **Verify before you claim.** Grep the repo and cite the code before stating what a mod does, especially before a GitHub comment or before closing an issue.
8. **Think ecosystem.** These mods interoperate. The integration backbone is the read contract: a mod publishes its handle on `g_currentMission.<handle>`, peers read it via `getfenv(0)["g_<Global>"]`, and writes go back only through admin-gated client to server events. See `ecosystem-map.md`.
9. **Disagreements go to the humans, no deadlock.** Tison decides on implementation, Arissani on design and integration. Write it up in the ledger, and do not silently overwrite the other agent's work.

The single source of truth for all of this is `CLAUDE-GEMINI-LOG.md` in the ecosystem-dev-tracking workspace. If this file and that one ever drift, that one wins.
