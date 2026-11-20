local addonName, ns = ...
-- Disenchant.lua
-- What gear disenchants into on WoW Forever, for the "Disenchant profit" sort.
-- Plain Lua 5.1 with no game API calls (Ledger.lua supplies the item facts and
-- material prices), so it can be tested outside the game.
--
-- The tables and rules are the ones in DEValueTooltip 2.0.0 (Data.lua and
-- Disenchant.lua), whose sources are Disenchantry 1.1.9 and the Warcraft Wiki
-- disenchanting tables. If yields change, change them in both addons.
--
-- Results depend on the item's ITEM LEVEL (not its required level) and quality;
-- uncommon armor favours dust, uncommon weapons favour essence. Within a
-- quantity range every quantity is equally likely unless a row gives an average.
-- Expected value = sum over the possible results of chance x average quantity x
-- unit price (the results are mutually exclusive).

local DE = {}
ns.Disenchant = DE

local M = {
    STRANGE_DUST     = 10940, SOUL_DUST        = 11083, VISION_DUST      = 11137,
    DREAM_DUST       = 11176, ILLUSION_DUST    = 16204,
    LESSER_MAGIC     = 10938, GREATER_MAGIC    = 10939, LESSER_ASTRAL    = 10998,
    GREATER_ASTRAL   = 11082, LESSER_MYSTIC    = 11134, GREATER_MYSTIC   = 11135,
    LESSER_NETHER    = 11174, GREATER_NETHER   = 11175, LESSER_ETERNAL   = 16202,
    GREATER_ETERNAL  = 16203,
    SMALL_GLIMMERING = 10978, LARGE_GLIMMERING = 11084, SMALL_GLOWING    = 11138,
    LARGE_GLOWING    = 11139, SMALL_RADIANT    = 11177, LARGE_RADIANT    = 11178,
    SMALL_BRILLIANT  = 14343, LARGE_BRILLIANT  = 14344,
    NEXUS_CRYSTAL    = 20725,
}
DE.MAT = M

-- Uncommon (green): dust/essence = { itemID, minQty, maxQty }, shard = itemID (1x)
-- armor/weapon = { dust %, essence %, shard % }
DE.UNCOMMON = {
    { lo = 1,  hi = 15, dust = { M.STRANGE_DUST, 1, 2 },  essence = { M.LESSER_MAGIC, 1, 2 },
      shard = nil,                armor = { 80, 20, 0 },  weapon = { 20, 80, 0 } },
    { lo = 16, hi = 20, dust = { M.STRANGE_DUST, 2, 3 },  essence = { M.GREATER_MAGIC, 1, 2 },
      shard = M.SMALL_GLIMMERING, armor = { 75, 20, 5 },  weapon = { 20, 75, 5 } },
    { lo = 21, hi = 25, dust = { M.STRANGE_DUST, 4, 6 },  essence = { M.LESSER_ASTRAL, 1, 2 },
      shard = M.SMALL_GLIMMERING, armor = { 75, 15, 10 }, weapon = { 15, 75, 10 } },
    { lo = 26, hi = 30, dust = { M.SOUL_DUST, 1, 2 },     essence = { M.GREATER_ASTRAL, 1, 2 },
      shard = M.LARGE_GLIMMERING, armor = { 75, 20, 5 },  weapon = { 20, 75, 5 } },
    { lo = 31, hi = 35, dust = { M.SOUL_DUST, 2, 5 },     essence = { M.LESSER_MYSTIC, 1, 2 },
      shard = M.SMALL_GLOWING,    armor = { 75, 20, 5 },  weapon = { 20, 75, 5 } },
    { lo = 36, hi = 40, dust = { M.VISION_DUST, 1, 2 },   essence = { M.GREATER_MYSTIC, 1, 2 },
      shard = M.LARGE_GLOWING,    armor = { 75, 20, 5 },  weapon = { 20, 75, 5 } },
    { lo = 41, hi = 45, dust = { M.VISION_DUST, 2, 5 },   essence = { M.LESSER_NETHER, 1, 2 },
      shard = M.SMALL_RADIANT,    armor = { 75, 20, 5 },  weapon = { 20, 75, 5 } },
    { lo = 46, hi = 50, dust = { M.DREAM_DUST, 1, 2 },    essence = { M.GREATER_NETHER, 1, 2 },
      shard = M.LARGE_RADIANT,    armor = { 75, 20, 5 },  weapon = { 20, 75, 5 } },
    { lo = 51, hi = 55, dust = { M.DREAM_DUST, 2, 5 },    essence = { M.LESSER_ETERNAL, 1, 2 },
      shard = M.SMALL_BRILLIANT,  armor = { 75, 20, 5 },  weapon = { 22, 75, 3 } },
    { lo = 56, hi = 60, dust = { M.ILLUSION_DUST, 1, 2 }, essence = { M.GREATER_ETERNAL, 1, 2 },
      shard = M.LARGE_BRILLIANT,  armor = { 75, 20, 5 },  weapon = { 22, 75, 3 } },
    { lo = 61, hi = 65, dust = { M.ILLUSION_DUST, 2, 5 }, essence = { M.GREATER_ETERNAL, 2, 3 },
      shard = M.LARGE_BRILLIANT,  armor = { 75, 20, 5 },  weapon = { 22, 75, 3 } },
}

-- Forever: uncommon WEAPONS of item level 21-30 give Greater Magic Essence
-- instead of the Astral essences. Armor keeps the Astral essences.
DE.FOREVER_WEAPON_ESSENCE = {
    { lo = 21, hi = 30, itemID = M.GREATER_MAGIC },
}

-- Rare (blue): result = { itemID, chance %, minQty, maxQty }
DE.RARE = {
    { lo = 1,  hi = 25, results = { { M.SMALL_GLIMMERING, 100, 1, 1 } } },
    { lo = 26, hi = 30, results = { { M.LARGE_GLIMMERING, 100, 1, 1 } } },
    { lo = 31, hi = 35, results = { { M.SMALL_GLOWING,    100, 1, 1 } } },
    { lo = 36, hi = 40, results = { { M.LARGE_GLOWING,    100, 1, 1 } } },
    { lo = 41, hi = 45, results = { { M.SMALL_RADIANT,    100, 1, 1 } } },
    { lo = 46, hi = 50, results = { { M.LARGE_RADIANT,    100, 1, 1 } } },
    { lo = 51, hi = 55, results = { { M.SMALL_BRILLIANT,  100, 1, 1 } } },
    { lo = 56, hi = 80, results = { { M.LARGE_BRILLIANT, 99.5, 1, 1 }, { M.NEXUS_CRYSTAL, 0.5, 1, 1 } } },
}

-- Epic (purple): result = { itemID, chance %, minQty, maxQty, avgQty (optional) }
-- weaponAvg replaces the average quantity for weapons in [weaponLo, weaponHi]
DE.EPIC = {
    { lo = 40, hi = 45, results = { { M.SMALL_RADIANT,   100, 2, 4 } } },
    { lo = 46, hi = 50, results = { { M.LARGE_RADIANT,   100, 2, 4 } } },
    { lo = 51, hi = 55, results = { { M.SMALL_BRILLIANT, 100, 2, 4 } } },
    { lo = 56, hi = 60, results = { { M.NEXUS_CRYSTAL,   100, 1, 1 } } },
    { lo = 61, hi = 88, results = { { M.NEXUS_CRYSTAL,   100, 1, 2 } },
      weaponLo = 76, weaponHi = 80, weaponAvg = 5 / 3 },
    -- epics above 88 aren't in the published tables: an estimate
    { lo = 89, hi = 100, results = { { M.NEXUS_CRYSTAL,  100, 1, 2 } }, estimated = true },
}

-- Gear that fits the rules but can't be disenchanted (enchanter-made wands)
DE.EXCLUDED = {
    [11287] = true, [11288] = true, [11289] = true, [11290] = true,
    [247789] = true, [249144] = true, [249234] = true, [249232] = true, [249237] = true, [249385] = true,
}

-- Slots that are never disenchantable
DE.BLOCKED_EQUIPLOC = {
    [""] = true, INVTYPE_NON_EQUIP = true, INVTYPE_NON_EQUIP_IGNORE = true, INVTYPE_BODY = true,
    INVTYPE_TABARD = true, INVTYPE_BAG = true, INVTYPE_QUIVER = true, INVTYPE_AMMO = true,
}

DE.CLASS_WEAPON, DE.CLASS_ARMOR = 2, 4        -- Enum.ItemClass values (set from Enum in Ledger.lua when present)
DE.BLOCKED_SUBCLASS = {
    [4] = { [5] = true },                     -- cosmetic armor
    [2] = { [20] = true },                    -- fishing poles
}

local function FindRow(rows, itemLevel)
    for _, row in ipairs(rows) do
        if itemLevel >= row.lo and itemLevel <= row.hi then return row end
    end
    return nil
end

local function Outcome(itemID, chance, minQty, maxQty, avgQty)
    minQty = minQty or 1
    maxQty = maxQty or minQty
    return { itemID = itemID, chance = chance, minQty = minQty, maxQty = maxQty, avgQty = avgQty or (minQty + maxQty) / 2 }
end

local function UncommonOutcomes(row, isWeapon, itemLevel)
    local odds = isWeapon and row.weapon or row.armor
    local essenceID = row.essence[1]
    if isWeapon then
        local override = FindRow(DE.FOREVER_WEAPON_ESSENCE, itemLevel)
        if override then essenceID = override.itemID end
    end
    local list = {
        Outcome(row.dust[1], odds[1], row.dust[2], row.dust[3]),
        Outcome(essenceID, odds[2], row.essence[2], row.essence[3]),
    }
    if row.shard and odds[3] > 0 then list[#list + 1] = Outcome(row.shard, odds[3], 1, 1) end
    return list
end

local function ListOutcomes(row, isWeapon, itemLevel)
    local list = {}
    for _, r in ipairs(row.results) do
        local avg = r[5]
        if isWeapon and row.weaponAvg and itemLevel >= row.weaponLo and itemLevel <= row.weaponHi then
            avg = row.weaponAvg
        end
        list[#list + 1] = Outcome(r[1], r[2], r[3], r[4], avg)
    end
    return list
end

-- info = { id, quality, itemLevel, classID, subclassID, equipLoc }
-- refuses = the item's own tooltip says "Cannot be disenchanted"
-- Returns nil for anything that isn't uncommon/rare/epic armor or weapons, or
--   { status = "ok", outcomes = {...}, estimated = bool }
--   { status = "cannot" }   (excluded item, blocked slot or subclass, or the tooltip says so)
--   { status = "nodata" }   (item level outside the tables)
function DE.Evaluate(info, refuses)
    if not info then return nil end
    local quality, classID = info.quality, info.classID
    if not quality or quality < 2 or quality > 4 then return nil end
    if classID ~= DE.CLASS_WEAPON and classID ~= DE.CLASS_ARMOR then return nil end
    if DE.EXCLUDED[info.id] then return { status = "cannot" } end
    if info.equipLoc == nil or DE.BLOCKED_EQUIPLOC[info.equipLoc] then return { status = "cannot" } end
    local blocked = DE.BLOCKED_SUBCLASS[classID]
    if blocked and info.subclassID and blocked[info.subclassID] then return { status = "cannot" } end
    if refuses then return { status = "cannot" } end

    local itemLevel = info.itemLevel
    if not itemLevel or itemLevel < 1 then return { status = "nodata" } end
    local isWeapon = classID == DE.CLASS_WEAPON
    local row, outcomes
    if quality == 2 then
        row = FindRow(DE.UNCOMMON, itemLevel)
        outcomes = row and UncommonOutcomes(row, isWeapon, itemLevel)
    elseif quality == 3 then
        row = FindRow(DE.RARE, itemLevel)
        outcomes = row and ListOutcomes(row, isWeapon, itemLevel)
    else
        row = FindRow(DE.EPIC, itemLevel)
        outcomes = row and ListOutcomes(row, isWeapon, itemLevel)
    end
    if not outcomes then return { status = "nodata" } end
    return { status = "ok", outcomes = outcomes, estimated = row.estimated and true or false }
end

-- Expected value in copper from priceFn(materialID) -> unit price or nil.
-- Returns value, partial (true when some possible material has no price), or
-- nil when no material has a price.
function DE.ExpectedValue(outcomes, priceFn)
    local total, priced, partial = 0, false, false
    for _, o in ipairs(outcomes) do
        local price = priceFn(o.itemID)
        if price and price > 0 then
            total = total + (o.chance / 100) * o.avgQty * price
            priced = true
        elseif o.chance > 0 then
            partial = true
        end
    end
    if not priced then return nil, partial end
    return total, partial
end
