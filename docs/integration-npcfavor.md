# Integrating with FieldSentry (contract providers)

FieldSentry is the backend gate inside FS25 Soil & Fertilizer that decides, per field,
whether the soil simulation should run right now. Phase 2 adds a small, decoupled API so
another mod can tell FieldSentry "this field is under one of my contracts" without S&F
ever depending on that mod, and without that mod touching the soil equations.

This guide is written for NPCFavor, but nothing here is NPCFavor-specific. Any mod that
runs field work the player should not be penalised for (favor harvests, AI helper jobs,
custom missions) can register the same way.

---

## The problem it solves

S&F simulates owned fields: harvests deplete N/P/K, and a depleted field yields less.
NPC neighbour fields are not managed by anyone, so under S&F their yield would crater,
and an NPC harvest favor would become mathematically impossible to complete.

FieldSentry fixes that by **masking** the field while a contract is active: the daily sim
skips it, so its soil values freeze and the contract harvest gets vanilla yields. When the
contract ends, FieldSentry can apply a one-shot **retroactive** nutrient catch-up so the
field does not sit frozen in stasis forever.

---

## API surface

All of these live on the global `FieldSentry_API` (guard with `if FieldSentry_API then`
so your mod still loads if S&F is absent).

| Function | Purpose |
|----------|---------|
| `registerContractProvider(name, fn)` | Register your eligibility callback. Returns `true` if registered. |
| `unregisterContractProvider(name)` | Remove it (on teardown). |
| `applyRetroactiveHarvest(fieldId, liters, fruitType, seq)` | One-shot nutrient catch-up when a contract finishes. |

Tunable: `FieldSentry_Core.FAVOR_TIER_THRESHOLD` (default `4`) — at or above this favor
tier a provider may keep S&F running instead of masking (see *Favor-tier exemption*).

---

## The callback contract

```lua
-- fn(fieldId) -> { active = boolean, favorTier = number, allowSAndF = boolean }
```

| Field | Meaning |
|-------|---------|
| `active` | **Required boolean.** `true` while one of your contracts is running on this field. |
| `favorTier` | Optional number (default `0`). The neighbour relationship tier for this field. |
| `allowSAndF` | Optional boolean (default `false`). `true` asks FieldSentry to let S&F keep running on the field instead of masking it, *if* `favorTier` is high enough. |

Hard rules, because FieldSentry **fails closed**:

- Return a **table**, always, with a real `boolean` in `active`. A `nil`, a non-table, a
  crash, or a non-boolean `active` is treated as "contract active, not exempt" — the field
  stays masked. A broken provider can never silently un-mask an NPC field.
- Keep it **non-blocking and cheap**. It is called per field on the daily sim seam, wrapped
  in `pcall`. No yields, no heavy lookups, no allocations you can avoid. An O(1) table read
  is the target.
- `fieldId` is the **farmland id** (the same id S&F uses everywhere).

---

## Server-only

Registration and evaluation are **server/host authoritative**. Register on the server (or
in single player); a pure client registration is ignored on purpose. Clients receive the
resulting mask through S&F's own sync, so you never send your own packets for this.

---

## Example: NPCFavor provider

```lua
-- In NPCFavor, once the mission is up and you are the server/host.
-- (Single player counts as the server, so this also runs in SP.)

local function npcFavorContractStatus(fieldId)
    -- Look up YOUR own state. Keep this fast and never error.
    local contract = NPCFavorManager and NPCFavorManager:getActiveContractForField(fieldId)
    if not contract then
        return { active = false }
    end

    local tier = (contract.neighbour and contract.neighbour.favorTier) or 0

    return {
        active     = true,
        favorTier  = tier,
        -- Best friends let you actually manage their soil; hostile neighbours don't,
        -- so their field is fully masked and the harvest gets vanilla yields.
        allowSAndF = tier >= (FieldSentry_Core.FAVOR_TIER_THRESHOLD or 4),
    }
end

if FieldSentry_API and FieldSentry_API.registerContractProvider then
    FieldSentry_API.registerContractProvider("NPCFavor", npcFavorContractStatus)
end
```

That is the whole masking integration. While a favor is active on a field, S&F leaves it
alone; when it ends, your next call returns `active = false` and S&F resumes on the next
daily tick.

---

## Favor-tier exemption (optional, progression)

By default every contract field is masked the same way. With `allowSAndF = true` and a
`favorTier` at or above the threshold, FieldSentry instead **leaves the sim running** on
the field and records a transient `contractExempt` hint (readable via
`FieldSentry_API.getUIStatus(fieldId).diagnosticHints`). Use this to reward high
relationships: a best friend lets the player prepare and benefit from real soil management
on the contract field, while a hostile neighbour's field stays a plain vanilla mask.

FieldSentry never flips a persistent player setting from a hint — the exemption is
recomputed live each refresh from what your callback returns.

---

## Retroactive nutrient catch-up (optional)

While a field is masked its soil is frozen. If you want the contract harvest to still leave
a realistic dent, call this once when the contract **completes**:

```lua
-- deliveredLiters: the yield the contract actually pulled off the field.
-- fruitType:       crop name string (e.g. "wheat"); nil uses default coefficients.
-- contractSeq:     a number that increases by 1 per contract on this field. It is the
--                  idempotency token: the same (or an older) seq is never applied twice,
--                  so a save/reload or a duplicate completion event can't double-dock.
FieldSentry_API.applyRetroactiveHarvest(fieldId, deliveredLiters, fruitType, contractSeq)
```

FieldSentry estimates the N/P/K drain from fixed per-crop coefficients (not the full sim)
and applies it in one cheap step, then bumps the stored sequence. If S&F's sim is not ready
yet (for example you call it during load), the catch-up is queued and applied automatically
on the next opportunity. In multiplayer the reconciled values are broadcast like any other
soil change, so clients stay in sync.

Keep `contractSeq` monotonic per field (a simple per-field counter you persist is fine).
That is what makes the call safe to fire more than once.

---

## Teardown

If your mod unloads mid-session, drop your provider so FieldSentry stops calling it:

```lua
if FieldSentry_API and FieldSentry_API.unregisterContractProvider then
    FieldSentry_API.unregisterContractProvider("NPCFavor")
end
```

---

## Checklist

- [ ] Register on the server/host only, after the mission loads.
- [ ] Callback returns a table with a boolean `active`, always, and never errors or blocks.
- [ ] Use `favorTier` + `allowSAndF` only if you want the progression exemption.
- [ ] Call `applyRetroactiveHarvest` on contract completion with a monotonic `contractSeq`.
- [ ] Guard every call with `if FieldSentry_API then` so your mod survives S&F being absent.
