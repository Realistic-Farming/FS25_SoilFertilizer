-- attached_product_resolution_809_test.lua - #809 Auto rate stuck at 1.00x on tractor + implement.
--   getApplicatorVehicle hands updateAutoRates the ROOT vehicle (the tractor). When no
--   spray work area is live and the tractor has no tanker spec, SoilHUD:getSprayerFillType
--   drops to its Priority 4 fallback. The old fallback walked only that vehicle's own fill
--   units and took the first non-empty one, which on a tractor is the fuel tank, so auto
--   rate read DIESEL, found no profile, and held 1.00x while lime went down at full rate.
--   The repair (ported from c776536b) skips fuel/DEF units, walks attached implements to
--   depth 3 plus the root, and prefers a unit holding a product with a FERTILIZER_PROFILES
--   entry before accepting any other non-fuel product.
--   Contract locked here: tractor + implement resolves the implement's product; a tractor
--   with only diesel resolves nothing (no fuel fallback); a self-propelled sprayer's own
--   tank still wins; the implement walk stops at depth 3; a profiled product beats an
--   unprofiled one regardless of order; resolveSprayerFillTypeIndex (#780) is untouched.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/utils/SoilUtils.lua, src/ui/SoilHUD.lua

FillType = FillType or { UNKNOWN = 0 }

-- Fill-type registry the fallback resolves indices through. Indices are arbitrary; only
-- the names matter (they key FERTILIZER_PROFILES and the fuel skip list).
local FT = { DIESEL = 11, DEF = 12, LIME = 21, LIQUIDFERTILIZER = 22, MYSTERYMIX = 23 }
local byIndex = {}
for name, idx in pairs(FT) do byIndex[idx] = { name = name, index = idx } end
g_fillTypeManager = {
  getFillTypeByIndex = function(_self, idx) return byIndex[idx] end,
}

-- A vehicle mock that looks like vanilla FillUnit + AttacherJoints:
--   getFillUnits() returns the fill-unit array, getFillUnitFillType(i) its fillType,
--   getAttachedImplements() returns { { object = <vehicle> }, ... } (AttacherJoints.lua:1005
--   returns spec.attachedImplements, whose entries carry .object).
local function vehicle(fillTypes, implements)
  local v = { spec_fillUnit = { fillUnits = {} }, spec_attacherJoints = { attachedImplements = {} } }
  for i, ft in ipairs(fillTypes or {}) do
    v.spec_fillUnit.fillUnits[i] = { fillType = ft, fillLevel = ft ~= FillType.UNKNOWN and 100 or 0 }
  end
  for _, impl in ipairs(implements or {}) do
    v.spec_attacherJoints.attachedImplements[#v.spec_attacherJoints.attachedImplements + 1] = { object = impl }
  end
  v.getFillUnits = function(self) return self.spec_fillUnit.fillUnits end
  v.getFillUnitFillType = function(self, i)
    local u = self.spec_fillUnit.fillUnits[i]
    return u and u.fillType or nil
  end
  v.getFillUnitFillLevel = function(self, i)
    local u = self.spec_fillUnit.fillUnits[i]
    return u and u.fillLevel or 0
  end
  v.getAttachedImplements = function(self) return self.spec_attacherJoints.attachedImplements end
  return v
end

local function link(root, impl)
  impl.rootVehicle = root
  root.rootVehicle = root
  return impl
end

local hud = setmetatable({ settings = {} }, { __index = SoilHUD })
local function resolvedName(v)
  local ft = hud:getSprayerFillType(v)
  return ft and ft.name or nil
end

-- ── The bug: tractor (diesel) + pulled spreader (lime) ──
do
  local spreader = vehicle({ FT.LIME })
  local tractor  = vehicle({ FT.DIESEL, FT.DEF }, { spreader })
  link(tractor, spreader)
  T.eq("809: tractor+spreader resolves the implement's LIME, not DIESEL",
       resolvedName(tractor), "LIME")
end

-- ── Same rig, liquid product (nitro's Berthoud + UAN family) ──
do
  local sprayer = vehicle({ FT.LIQUIDFERTILIZER })
  local tractor = vehicle({ FT.DIESEL }, { sprayer })
  link(tractor, sprayer)
  T.eq("809: tractor+trailed sprayer resolves LIQUIDFERTILIZER",
       resolvedName(tractor), "LIQUIDFERTILIZER")
end

-- ── Tractor alone: fuel is never a product ──
do
  local tractor = vehicle({ FT.DIESEL, FT.DEF })
  tractor.rootVehicle = tractor
  T.eq("809: tractor alone with diesel+DEF resolves nothing", resolvedName(tractor), nil)
end

-- ── Self-propelled sprayer: its own tank still wins (regression guard) ──
do
  local sp = vehicle({ FT.DIESEL, FT.LIQUIDFERTILIZER })
  sp.rootVehicle = sp
  T.eq("809: self-propelled sprayer resolves its own product tank",
       resolvedName(sp), "LIQUIDFERTILIZER")
end

-- ── Called with the implement, root walked too ──
do
  local spreader = vehicle({ FT.UNKNOWN })
  local tractor  = vehicle({ FT.DIESEL, FT.LIME }, { spreader })  -- e.g. front tank on the root
  link(tractor, spreader)
  T.eq("809: implement with empty hopper falls back to the root's product",
       resolvedName(spreader), "LIME")
end

-- ── Two-pass choice: a profiled product beats an unprofiled one, regardless of order ──
do
  local a = vehicle({ FT.MYSTERYMIX })
  local b = vehicle({ FT.LIME })
  local tractor = vehicle({ FT.DIESEL }, { a, b })
  link(tractor, a); link(tractor, b)
  T.eq("809: profiled LIME preferred over an earlier unprofiled product",
       resolvedName(tractor), "LIME")
end
do
  local a = vehicle({ FT.MYSTERYMIX })
  local tractor = vehicle({ FT.DIESEL }, { a })
  link(tractor, a)
  T.eq("809: an unprofiled non-fuel product still resolves as a fallback",
       resolvedName(tractor), "MYSTERYMIX")
end

-- ── Depth limit: the walk stops at depth 3 below the vehicle it starts from ──
-- chain(depth) builds tractor -> d1 -> d2 -> ... -> d<depth>, product only on the last link.
local function chain(depth)
  local tail = vehicle({ FT.LIME })
  local child = tail
  for _ = depth - 1, 1, -1 do
    child = vehicle({ FT.UNKNOWN }, { child })
  end
  local tractor = vehicle({ FT.DIESEL }, { child })
  local walk = child
  while walk do
    link(tractor, walk)
    local next = walk.spec_attacherJoints.attachedImplements[1]
    walk = next and next.object or nil
  end
  return tractor
end
T.eq("809: product at depth 3 is found", resolvedName(chain(3)), "LIME")
T.eq("809: product at depth 4 is beyond the walk (depth limit respected)",
     resolvedName(chain(4)), nil)

-- ── Fail-safe: a throwing getAttachedImplements never crashes the caller ──
do
  local tractor = vehicle({ FT.DIESEL })
  tractor.rootVehicle = tractor
  tractor.getAttachedImplements = function() error("boom") end
  T.eq("809: throwing getAttachedImplements fails safe to nil", resolvedName(tractor), nil)
end

-- ── Priority 2 (#780) is not touched: an active spray work area still wins ──
do
  local sprayer = vehicle({ FT.LIME })
  sprayer.spec_sprayer = { workAreaParameters = { sprayFillType = FT.LIQUIDFERTILIZER, sprayVehicle = nil } }
  sprayer.getSprayerFillUnitIndex = function() return 1 end
  sprayer.rootVehicle = sprayer
  T.eq("809: #708/#780 physical-tank rule still wins ahead of the fallback",
       resolvedName(sprayer), "LIME")
end
