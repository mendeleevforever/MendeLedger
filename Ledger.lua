local addonName, ns = ...
-- Ledger.lua
-- Copies Auctionator's daily prices into MendeLedgerDB and answers questions
-- about them for the window.
--
-- Where the prices come from (read only, Auctionator's data is never changed):
--   * while you play, Auctionator keeps the current realm as a plain table at
--     Auctionator.Database.db: [key] = { h = {[day] = highest daily low},
--     l = {[day] = lowest daily low, only when different}, a = {[day] = most
--     units seen}, m = latest minimum buyout }
--   * other realms (and the current one after logout) sit in
--     AUCTIONATOR_PRICE_DATABASE[realm] as CBOR strings; they are decoded
--     into a copy when imported
--
-- When it records:
--   * a few seconds after the auction house closes, and after a full scan
--     arrives (REPLICATE_ITEM_LIST_UPDATE)
--   * shortly after login, which catches scans made while MendeLedger was off
--     (Auctionator keeps its last 21 days, so nothing in that window is lost)
--   * /mendel record, the Record Now button, the minimap button (right-click)
--
-- Only "today" changes in Auctionator's data, so a realm remembers the last
-- day that was final when it was recorded ("settled"); later recordings only
-- merge newer days. Sealed blocks (Codec.lua) are therefore never rewritten.
--
-- Scan detail: Auctionator keeps one low/high/quantity per day, so the shape
-- of a day is lost. Every full or summary scan passes its results through
-- Auctionator.Database:ProcessScan(info), info[key] = { {price, available}, ... }.
-- A post-hook on that call (hooksecurefunc: it runs after Auctionator's own
-- code and changes nothing) gives MendeLedger each scan as it happens. Each
-- item's scan records reuse the Codec format: the "day" field holds a scan
-- number, low = high = lowest buyout in that scan, quantity = units on sale.
-- realm.scans.log maps scan numbers to times; scan detail is kept for a
-- limited number of days (keepScanDays), the daily ledger for as long as asked.

local ML, Codec = ns.ML, ns.Codec
local Num, Text = ns.Num, ns.Text
local floor = math.floor

local Ledger = {}
ns.Ledger = Ledger

local LC = LibStub and LibStub("LibCompress", true)

-------------------------------------------------------------------------------
-- Compression plug-in. Deflate comes from the game (C_EncodingUtil) through
-- LibCompress. Without it nothing is compressed: measured on 128-day blocks,
-- LibCompress's pure Lua LZW/Huffman never reach the 10% saving that makes
-- compression worth it, so trying would only cost CPU.
-------------------------------------------------------------------------------
if LC and LC.HasZlibCodecs and LC:HasZlibCodecs() then         -- RETEST: C_EncodingUtil
    Codec.compress = function(raw) return (LC:CompressDeflate(raw, "size")) end
    Ledger.compressMethod = "Deflate (the game's built-in zlib)"
end
if LC then
    Codec.decompress = function(packed) return (LC:Decompress(packed)) end
end

function Ledger:CanCompress()
    return Codec.compress ~= nil
end

-------------------------------------------------------------------------------
-- Auctionator
-------------------------------------------------------------------------------
local function A() return rawget(_G, "Auctionator") end

function Ledger:AuctionatorPresent()
    return type(A()) == "table" or type(rawget(_G, "AUCTIONATOR_PRICE_DATABASE")) == "table"
end

function Ledger:AuctionatorVersion()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or rawget(_G, "GetAddOnMetadata")
    return Text((ns.SafeCall(get, "Auctionator", "Version")))
end

-- Auctionator's own history window in days (21 unless changed in its options)
function Ledger:AuctionatorDays()
    local cfg = rawget(_G, "AUCTIONATOR_CONFIG")
    return type(cfg) == "table" and Num(cfg.price_history_days) or 21     -- RETEST
end

-------------------------------------------------------------------------------
-- Auction houses. WoW Forever has no realms: one auction house serves everyone
-- in the same region, ruleset and faction. MendeLedger files prices under that,
-- as a key such as "US-PvE-Alliance" (shown "US / PvE / Alliance"). Nothing is
-- keyed by realm. Region, ruleset and faction are read only with GetRegion,
-- GetRuleset (both as given in the addon guidelines) and UnitFactionGroup.
-------------------------------------------------------------------------------
local REGION_CODES = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }
local REGION_SHOWN = { KRTW = "KR/TW" }
local FACTIONS = { Alliance = true, Horde = true }
local AH = "^(%a+)%-(%a+)%-(%a+)$"
Ledger.migrating = {}

-- GetRegion: the regionID of the player's Battle.net game account first, then
-- the portal-based functions. Returns the region code and where it came from.
local function GetRegion()
    if C_BattleNet and C_BattleNet.GetGameAccountInfoByGUID then                   -- RETEST
        local info = ns.SafeCall(C_BattleNet.GetGameAccountInfoByGUID, (ns.SafeCall(UnitGUID, "player")))
        local id = type(info) == "table" and Num(info.regionID) or nil
        if id and REGION_CODES[id] then return REGION_CODES[id], "Battle.net game account" end
    end
    if GetCurrentRegionName then                                                      -- RETEST
        local name = Text((ns.SafeCall(GetCurrentRegionName)))
        if name and name:match("^%a+$") then return name:upper(), "portal name" end
    end
    if GetCurrentRegion then                                                          -- RETEST
        local id = Num((ns.SafeCall(GetCurrentRegion)))
        if id and REGION_CODES[id] then return REGION_CODES[id], "portal ID" end
    end
    return nil
end

-- KR and TW count as one region group ("KRTW", shown "KR/TW") until a Taiwan
-- player confirms that the regionID reads TW on Forever
function Ledger:Region()
    local region, source = GetRegion()
    if region == "KR" or region == "TW" then region = "KRTW" end
    return region, source
end

-- GetRuleset: Hardcore, then RP, then PvP, otherwise PvE. nil when the
-- functions are missing on this build (or a rule's answer is secret).
local function GetRuleset()
    if not (C_GameRules and C_GameRules.IsGameRuleActive and Enum and Enum.GameRule) then   -- RETEST
        return nil
    end
    local unknown = false
    local function active(name)
        local id = Enum.GameRule[name]
        if id == nil then return false end
        local v = ns.SafeCall(C_GameRules.IsGameRuleActive, id)
        if ns.IsSecret(v) then unknown = true return false end
        return v and true or false
    end
    local ruleset = (active("HardcoreRuleset") and "Hardcore") or (active("RPRuleset") and "RP")
        or (active("PvPRuleset") and "PvP") or "PvE"
    if unknown then return nil end
    return ruleset
end
Ledger.Ruleset = function() return GetRuleset() end

-- "Alliance" or "Horde" from UnitFactionGroup("player"); a secret or missing
-- value counts as unknown
function Ledger:Faction()
    local f = Text((ns.SafeCall(rawget(_G, "UnitFactionGroup"), "player")))  -- RETEST
    return (f and FACTIONS[f]) and f or nil
end

function Ledger:AuctionHouseKey()
    local region, ruleset, faction = self:Region(), GetRuleset(), self:Faction()
    if region and ruleset and faction then return region .. "-" .. ruleset .. "-" .. faction end
    return nil
end

function Ledger.IsAuctionHouseKey(key)
    if type(key) ~= "string" then return false end
    local _, _, faction = key:match(AH)
    return faction ~= nil and FACTIONS[faction] == true
end

local RULESET_SHOWN = { RPPvP = "RP-PvP" }                   -- only in keys 0.2.8 made
function Ledger.AuctionHouseName(key)
    local region, ruleset, faction = key:match(AH)
    if not region then return key end
    return (REGION_SHOWN[region] or region) .. " / " .. (RULESET_SHOWN[ruleset] or ruleset) .. " / " .. faction
end

-- Auctionator 350+ names its Forever price lists "<ruleset> <faction>". This
-- only tells which auction house such a list belongs to (the ruleset itself is
-- read with GetRuleset): Auctionator's "RPPvP" is RP, because GetRuleset sees
-- RP first, and "HC" is Hardcore.
local AUCTIONATOR_RULESETS = { PvE = "PvE", PvP = "PvP", RP = "RP", RPPvP = "RP", HC = "Hardcore" }
function Ledger.ParseAuctionatorList(aKey)
    if type(aKey) ~= "string" then return nil end
    local r, f = aKey:match("^(%a+) (%a+)$")                              -- RETEST: Auctionator 350's list names
    local ruleset = r and AUCTIONATOR_RULESETS[r]
    if ruleset and FACTIONS[f] then return ruleset, f end
    return nil
end

-- Migration only: region group and ruleset of a key saved before 0.2.7, when
-- MendeLedger and Auctionator still filed prices by realm ("CAMWOWUS1Realm3PvE").
-- Nothing new is ever keyed this way.
function Ledger.ParseOldKey(key)
    if type(key) ~= "string" then return nil end
    local region = key:match("^CAMWOW(%a%a)%d")
    if region == "KR" or region == "TW" then region = "KRTW"
    elseif region ~= "US" and region ~= "EU" and region ~= "CN" then return nil end
    local tail = key:match("Realm%d+(%a+)$")
    tail = tail and tail:lower()
    local ruleset = (tail == "pve" and "PvE") or (tail == "pvp" and "PvP") or ((tail == "rp" or tail == "rppvp") and "RP")
        or ((tail == "hardcore" or tail == "hc") and "Hardcore") or nil
    return region, ruleset
end

-- Auctionator's key for this session's price list, or nil
function Ledger:AuctionatorKey()
    local Au = A()
    if type(Au) == "table" and type(Au.State) == "table" and type(Au.State.CurrentRealm) == "string" then
        return Au.State.CurrentRealm
    end
    return nil
end

-- Notes which of Auctionator's price lists this auction house uses, names its
-- entry, and moves in history from entries that belong to it
function Ledger:NoteAuctionHouse(key, previous)
    if self.noted == key then return end
    self.noted = key
    local h = ML.db.houses[key] or {}
    ML.db.houses[key] = h
    h.seen = time()
    local aKey = self:AuctionatorKey()
    if aKey ~= nil then
        h.aKey = aKey
        if type(h.aKeys) ~= "table" then h.aKeys = {} end
        h.aKeys[aKey] = true                          -- every list it has used, for Import All
    end
    local entry = self:Realm(key, true)
    entry.name = entry.name or Ledger.AuctionHouseName(key)
    -- The character's auction house under an older name (0.2.8 named rulesets
    -- after Auctionator, e.g. "RPPvP"; 0.2.7-0.2.9 called KR, TW and CN "Other")
    -- is moved into this one, then removed. A character can't change region
    -- or ruleset, so these can only be renames.
    if previous and previous ~= key and Ledger.IsAuctionHouseKey(previous) and ML.db.realms[previous] then
        local pr, prs, pf = previous:match(AH)
        local r, rs, f = key:match(AH)
        if pf == f and ((pr == r and prs ~= rs) or (pr == "Other" and prs == rs)) then
            local old = ML.db.realms[previous]
            if type(old.dropAfter) ~= "table" then old.dropAfter = {} end
            old.dropAfter[key] = true
            self:MergeEntry(previous, key)
        end
    end
    self:MigrateLegacy(key)
end

-- True (and the other house) when Auctionator keeps one price list for this
-- and another of the account's auction houses. Its daily prices then can't be
-- told apart, so MendeLedger records this house from its own scans only.
function Ledger:AuctionatorShared(key)
    local mine = key and ML.db.houses[key]
    local aKey = mine and mine.aKey
    if aKey == nil then return false end
    for other, h in pairs(ML.db.houses) do
        if other ~= key and h.aKey == aKey then return true, other end
    end
    return false
end

-- Entries from before auction houses are moved into the auction houses they
-- belong to, then removed, so no saved data stays keyed by realm:
--   * old realm keys ("CAMWOWUS1Realm3PvE"): into this auction house and the
--     account's other known auction houses with the same region and ruleset
--     (the old data never told factions apart)
--   * entries named after an Auctionator list ("PvE Alliance", made by
--     0.2.7's Import All): into that list's auction house
--   * anything else that this character was recorded into under 0.2.6
function Ledger:MigrateLegacy(key)
    local region, ruleset = key:match(AH)
    local char = ML.charDB
    local list = {}
    for oldKey in pairs(ML.db.realms) do list[#list + 1] = oldKey end   -- entries may be removed below
    for _, oldKey in ipairs(list) do
        local old = ML.db.realms[oldKey]
        if old and oldKey ~= key and not Ledger.IsAuctionHouseKey(oldKey) then
            local targets = {}
            local lr, lf = Ledger.ParseAuctionatorList(oldKey)
            if lr then
                targets[region .. "-" .. lr .. "-" .. lf] = true
            else
                local r, rs = Ledger.ParseOldKey(oldKey)
                if (r and r == region and rs == ruleset) or (char ~= nil and char.realm == oldKey) then
                    targets[key] = true
                    for houseKey in pairs(ML.db.houses) do
                        local hr, hrs = houseKey:match(AH)
                        if hr == region and hrs == ruleset then targets[houseKey] = true end
                    end
                end
            end
            if next(targets) then
                if type(old.dropAfter) ~= "table" then old.dropAfter = {} end
                for target in pairs(targets) do
                    old.dropAfter[target] = true
                    self:MergeEntry(oldKey, target)
                end
            end
        end
    end
end

-- Moves one entry into an auction house: daily prices, then scan detail, each
-- once; the entry is removed once everything is in every auction house it
-- belongs to (DropLegacy)
function Ledger:MergeEntry(fromKey, toKey)
    local old = ML.db.realms[fromKey]
    if not old then return end
    if type(old.mergedInto) ~= "table" then old.mergedInto = {} end
    if type(old.scansMergedInto) ~= "table" then old.scansMergedInto = {} end
    local tag = fromKey .. ">" .. toKey
    if not old.mergedInto[toKey] and not self.migrating[tag] then
        self.migrating[tag] = true
        self:StartMerge(fromKey, toKey)
    end
    local hasScans = type(old.scans) == "table" and type(old.scans.log) == "table" and next(old.scans.log) ~= nil
    if not hasScans then
        old.scansMergedInto[toKey] = true
    elseif not old.scansMergedInto[toKey] and not self.migrating["scans:" .. tag] then
        self.migrating["scans:" .. tag] = true
        self:StartScanMerge(fromKey, toKey)
    end
    self:DropLegacy(fromKey)
end

function Ledger:DropLegacy(fromKey)
    local old = ML.db.realms[fromKey]
    if not old or type(old.dropAfter) ~= "table" or not next(old.dropAfter) then return end
    for target in pairs(old.dropAfter) do
        if not (type(old.mergedInto) == "table" and old.mergedInto[target]) then return end
        if not (type(old.scansMergedInto) == "table" and old.scansMergedInto[target]) then return end
    end
    local name = self:RealmName(fromKey)
    local into = {}
    for target in pairs(old.dropAfter) do into[#into + 1] = self:RealmName(target) end
    table.sort(into)
    ML.db.realms[fromKey] = nil
    self.index[fromKey] = nil
    if ML.db.settings.realm == fromKey then ML.db.settings.realm = nil end
    ns.Print(("removed the entry %s: everything in it is now in %s."):format(name, table.concat(into, " and ")))
    ML:RequestUIRefresh(nil, true)
end

-- Scan detail: both scan logs are renumbered into one, in time order, and
-- every item's scan records are remapped and merged. It runs as one job; new
-- scans wait for it (NextScan checks scanMerging) and the target's tables are
-- refilled in place at the end, so other jobs holding them stay valid.
function Ledger:StartScanMerge(fromKey, toKey)
    local from = self:Realm(fromKey)
    local src = from and from.scans
    if not src then return end
    self.scanMerging = (self.scanMerging or 0) + 1
    local function Remap(s, map)
        local out = Codec.NewList()
        if not s then return out end
        local L = Codec.Decode(s)
        for i = 1, L.n do
            local id = map[L.d[i]]                    -- records of scans no longer in the log are dropped
            if id then Codec.Push(out, id, L.l[i], L.h[i], L.q[i]) end
        end
        return out
    end
    local job = { name = "scanmerge", label = "moving scan detail into " .. self:RealmName(toKey), i = 1, keys = {} }
    function job:Setup()                              -- on the first step, so scans saved before it are included
        local dst = Ledger:Scans(toKey, true)
        local all = {}
        for id, t in pairs(dst.log) do all[#all + 1] = { t, 1, id } end
        for id, t in pairs(src.log) do all[#all + 1] = { t, 2, id } end
        table.sort(all, function(x, y)
            if x[1] ~= y[1] then return x[1] < y[1] end
            if x[2] ~= y[2] then return x[2] < y[2] end
            return x[3] < y[3]
        end)
        self.mapD, self.mapS, self.log, self.count, self.full = {}, {}, {}, {}, {}
        for i, e in ipairs(all) do
            local store = (e[2] == 1) and dst or src
            if e[2] == 1 then self.mapD[e[3]] = i else self.mapS[e[3]] = i end
            self.log[i], self.count[i], self.full[i] = e[1], store.count[e[3]], store.full[e[3]] or nil
        end
        self.n, self.dst, self.newItems, self.records = #all, dst, {}, 0
        local seen = {}
        for k in pairs(dst.items) do seen[k] = true; self.keys[#self.keys + 1] = k end
        for k in pairs(src.items) do if not seen[k] then self.keys[#self.keys + 1] = k end end
    end
    function job:Step(deadline)
        if not self.dst then self:Setup() end
        local compress, dst, list, n = ML.db.settings.compress, self.dst, self.keys, #self.keys
        while self.i <= n do
            local k = list[self.i]
            self.i = self.i + 1
            local C = Codec.MergeLists(Remap(dst.items[k], self.mapD), Remap(src.items[k], self.mapS))
            if C.n > 0 then
                self.newItems[k] = Codec.Merge(nil, C, C.l[C.n], compress, nil)
                self.records = self.records + C.n
            end
            if ns.Clock() >= deadline then return false end
        end
        return true
    end
    function job:Progress() return self.i - 1, #self.keys end
    function job:OnDone()
        Ledger.scanMerging = (Ledger.scanMerging or 1) - 1
        if Ledger.scanMerging <= 0 then Ledger.scanMerging = nil end
        if not self.failed and self.dst then
            local dst = self.dst
            wipe(dst.log); wipe(dst.count); wipe(dst.full); wipe(dst.items)
            for i = 1, self.n do dst.log[i], dst.count[i], dst.full[i] = self.log[i], self.count[i], self.full[i] end
            for k, v in pairs(self.newItems) do dst.items[k] = v end
            dst.seq = self.n
            if (dst.lastFull or 0) == 0 then dst.lastFull = src.lastFull or 0 end
            if type(from.scansMergedInto) ~= "table" then from.scansMergedInto = {} end
            from.scansMergedInto[toKey] = true
            Ledger.scanHist = nil
            ns.Print(("moved the scan detail recorded under %s into %s (%s scans now)."):format(
                Ledger:RealmName(fromKey), Ledger:RealmName(toKey), ns.Commas(self.n)))
            Ledger:PruneScans(toKey, true)
            Ledger:RefreshScanStats(toKey)
            Ledger:DropLegacy(fromKey)
        end
        Ledger:NextScan()
        ML:RequestUIRefresh(nil, true)
    end
    ns.StartJob(job)
end

function Ledger:StartMerge(fromKey, toKey)
    local from, to = self:Realm(fromKey), self:Realm(toKey, true)
    if not from or not to then return end
    local keys = {}
    for k in pairs(from.items) do keys[#keys + 1] = k end
    local job = { name = "merge", label = "moving old history into " .. self:RealmName(toKey), keys = keys, i = 1, added = 0 }
    function job:Step(deadline)
        local compress, today = ML.db.settings.compress, ns.Today()
        local list, n = self.keys, #self.keys
        while self.i <= n do
            local k = list[self.i]
            self.i = self.i + 1
            local src = from.items[k]
            local L = src and Codec.Decode(src)
            if L and L.n > 0 then
                local cur = to.items[k]
                local om, _, _, _, olast = Codec.Summary(src)
                local m = om
                if cur then
                    local cm, _, _, _, clast = Codec.Summary(cur)
                    if cm and (clast or 0) >= (olast or 0) then m = cm end
                end
                local new, added = Codec.Merge(cur, L, m, compress, today)
                if new and new ~= cur then
                    to.items[k] = new
                    self.added = self.added + added
                    Ledger:IndexPut(toKey, k, new)
                end
            end
            if ns.Clock() >= deadline then return false end
        end
        return true
    end
    function job:Progress() return self.i - 1, #self.keys end
    function job:OnDone()
        if self.failed then return end
        from.mergedInto[toKey] = true
        if ML.db.settings.realm == fromKey then ML.db.settings.realm = nil end
        Ledger.hist = nil
        ns.Print(("moved the history recorded under %s into %s (%s daily prices). The old entry stays on the Options tab until you forget it."):format(
            Ledger:RealmName(fromKey), Ledger:RealmName(toKey), ns.Commas(self.added)))
        Ledger:RefreshStats(toKey)
        Ledger:DropLegacy(fromKey)
        ML:RequestUIRefresh(nil, true)
    end
    ns.StartJob(job)
end

-- The auction house this character's prices are filed under. In order:
--   1. from the game (GetRegion, GetRuleset, UnitFactionGroup), remembered for
--      the character in MendeLedgerCharDB.ah (a per-character saved variable).
--      A character can't change region, so when only the region reads
--      differently from the remembered one (the portal setting can be wrong),
--      the remembered one is kept: a misread region never splits a history.
--   2. the auction house remembered for this character
--   3. the only auction house in the ledger
--   4. nil: nothing is recorded, and MendeLedger says once how to choose
--      (/mendel use <name>, or Use Here on the Options tab)
-- self.houseSource says which: game, remembered, only, unknown.
function Ledger:CurrentRealmKey()
    local char = ML.charDB
    local remembered = char and Ledger.IsAuctionHouseKey(char.ah) and char.ah or nil
    local live = self:AuctionHouseKey()
    if live then
        local key = live
        self.regionMismatch = nil
        if remembered and remembered ~= live then
            local rr, rrs, rf = remembered:match(AH)
            local lr, lrs, lf = live:match(AH)
            if rr ~= lr and rrs == lrs and rf == lf and rr ~= "Other" then
                key, self.regionMismatch = remembered, lr
            end
        end
        if char then char.ah = key end
        self.houseSource = "game"
        self:NoteAuctionHouse(key, remembered)
        return key
    end
    if remembered then
        self.houseSource = "remembered"
        return remembered
    end
    local only, count = nil, 0
    for k in pairs(ML.db.realms) do
        if Ledger.IsAuctionHouseKey(k) then count = count + 1; only = k end
    end
    if count == 1 then
        if char then char.ah = only end
        self.houseSource = "only"
        if not self.onlyNoticed then
            self.onlyNoticed = true
            ns.Print(("MendeLedger couldn't read this character's region, ruleset or faction, so it records into %s, the only auction house it has. If that's wrong, type /mendel use <name>."):format(self:RealmName(only)))
        end
        return only
    end
    self.houseSource = "unknown"
    return nil
end

function Ledger:RealmUnknownNotice()
    if self.unknownNoticed then return end
    self.unknownNoticed = true
    ns.Print("MendeLedger couldn't read this character's region, ruleset or faction, so it doesn't know which auction house to record into. "
        .. "Open the Options tab, click the right auction house and press |cffffd100Use Here|r, or type |cffffd100/mendel use <name>|r. /mendel probe shows what's missing. Nothing is lost meanwhile: Auctionator keeps its last 21 days.")
end

-- /mendel use <name> and the Use Here button: record this character into an
-- existing auction house (only needed when the game won't say which)
function Ledger:SetCharacterHouse(text)
    text = ns.Trim(text or "")
    local key = text ~= "" and self:FindRealm(text) or nil
    if not key or not Ledger.IsAuctionHouseKey(key) then
        local names = {}
        for k in pairs(ML.db.realms) do if Ledger.IsAuctionHouseKey(k) then names[#names + 1] = self:RealmName(k) end end
        table.sort(names)
        ns.Print(#names > 0 and ("no auction house matches \"%s\". The ones MendeLedger has: %s."):format(text, table.concat(names, ", "))
            or "MendeLedger has no auction houses yet: it needs one character whose region, ruleset and faction it can read.")
        return nil
    end
    if ML.charDB then ML.charDB.ah = key end
    self.unknownNoticed, self.onlyNoticed = nil, true
    ns.Print(("this character's prices are now recorded into %s."):format(self:RealmName(key)))
    ML:ShowRealm(key)
    self:RecordNow("auction house chosen", true)
    return key
end

function Ledger:DecodeCBOR(s)
    if type(s) ~= "string" then return nil end
    if C_EncodingUtil and C_EncodingUtil.DeserializeCBOR then   -- RETEST
        local ok, t = pcall(C_EncodingUtil.DeserializeCBOR, s)
        if ok and type(t) == "table" then return t end
    end
    local CBOR = LibStub and LibStub("LibCBOR-1.0", true)       -- ships with Auctionator
    if CBOR then
        local ok, t = pcall(CBOR.Deserialize, CBOR, s)
        if ok and type(t) == "table" then return t end
    end
    return nil
end

-- The live price table for the current realm, its key, or nil + reason
function Ledger:LiveSource()
    local key = self:CurrentRealmKey()
    local cfg = rawget(_G, "AUCTIONATOR_CONFIG")
    if type(cfg) == "table" and cfg.no_price_database == true then
        return nil, key, "Auctionator's price database is turned off in its options."
    end
    local Au = A()
    if type(Au) == "table" and type(Au.Database) == "table" and type(Au.Database.db) == "table" then   -- RETEST
        return Au.Database.db, key
    end
    local root = rawget(_G, "AUCTIONATOR_PRICE_DATABASE")
    if type(root) ~= "table" then return nil, key, "Auctionator isn't loaded, so there is nothing new to record." end
    if not key then return nil, nil, "MendeLedger doesn't know which auction house this character uses yet. Use /mendel use <name>." end
    local aKey = self:AuctionatorKey()
    local v = aKey ~= nil and root[aKey] or nil
    if type(v) == "table" then return v, key end
    if type(v) == "string" then
        local t = self:DecodeCBOR(v)
        if t then return t, key end
        return nil, key, "Auctionator's prices for this auction house couldn't be unpacked."
    end
    return nil, key, "Auctionator has no prices for this auction house yet. Scan the auction house first."
end

function Ledger:SourceProbe(Add)
    local present = self:AuctionatorPresent()
    local aKey = self:AuctionatorKey()
    local list = (aKey == "" and ", one price list for everything (versions before 350)")
        or (Ledger.ParseAuctionatorList(aKey) and (", price list \"" .. aKey .. "\""))
        or (aKey and (", price list \"" .. aKey .. "\"")) or ""
    Add("Auctionator", present, present and ("version " .. (self:AuctionatorVersion() or "?") .. list) or "not loaded (the ledger still opens)")
    local root = rawget(_G, "AUCTIONATOR_PRICE_DATABASE")
    if type(root) == "table" then
        local v = Num(root.__dbversion)
        Add("Price database format", v == 8, ("version %s (written for 8)"):format(tostring(v or "?")))   -- RETEST
    end
    local key = self:CurrentRealmKey()
    local region, regionSource = self:Region()
    local where = ({
        game = "from the game",
        remembered = "remembered for this character",
        only = "the only auction house in the ledger",
    })[self.houseSource or ""]
    local detail
    if key then
        detail = self:RealmName(key) .. ", " .. where
        if regionSource then detail = detail .. "; region from the " .. regionSource end
        if self.regionMismatch then
            detail = detail .. "; the region now reads " .. self.regionMismatch .. ", so the remembered one is kept"
        end
    else
        detail = ("unknown (region %s, ruleset %s, faction %s); use /mendel use <name>"):format(
            tostring(region or "?"), tostring(self.Ruleset() or "?"), tostring(self:Faction() or "?"))
    end
    Add("Auction house", key ~= nil, detail)
    local shared, other = self:AuctionatorShared(key)
    if key and shared then
        Add("Daily prices", true, ("from MendeLedger's own scans (Auctionator shares one price list with %s)"):format(self:RealmName(other)))
    end
    local src, _, err = self:LiveSource()
    Add("Auctionator prices", src ~= nil, src and "Auctionator's prices for this session" or err)
    Add("Scan detail", self.scanHook,
        self.scanHook and "hooked into Auctionator.Database:ProcessScan" or "Auctionator's scan processing wasn't found, so only daily prices are recorded")
    Add("Day numbering", true, ("today is day %d (%s)"):format(ns.Today(), ns.DayDate(ns.Today())))
end

-------------------------------------------------------------------------------
-- Realms in the ledger
-------------------------------------------------------------------------------
function Ledger:Realm(key, create)
    if type(key) ~= "string" or key == "" then return nil end
    local realms = ML.db.realms
    local r = realms[key]
    if not r and create then
        r = { items = {}, created = time() }
        realms[key] = r
    end
    return r
end

function Ledger:RealmName(key)
    local r = key and ML.db.realms[key]
    if r and Text(r.name) then return r.name end
    if Ledger.IsAuctionHouseKey(key) then return Ledger.AuctionHouseName(key) end
    return key or "?"
end

function Ledger:RealmList()
    local out = {}
    for key, r in pairs(ML.db.realms) do
        local st = r.stats or {}
        out[#out + 1] = { key = key, name = self:RealmName(key), items = st.items or 0, lastRecord = r.lastRecord,
                          first = st.first, last = st.last, old = not Ledger.IsAuctionHouseKey(key),
                          merged = type(r.mergedInto) == "table" and next(r.mergedInto) ~= nil }
    end
    table.sort(out, function(a, b) return (a.lastRecord or 0) > (b.lastRecord or 0) end)
    return out
end

function Ledger:FindRealm(text)
    text = ns.Trim(text or ""):lower()
    if text == "" then return nil end
    for key in pairs(ML.db.realms) do
        if key:lower() == text or self:RealmName(key):lower() == text then return key end
    end
    for key in pairs(ML.db.realms) do
        if key:lower():find(text, 1, true) or self:RealmName(key):lower():find(text, 1, true) then return key end
    end
    return nil
end

-- The realm the window shows: the one picked, else the current one, else the most recent
function Ledger:ShownRealm()
    local realms = ML.db.realms
    local pick = ML.db.settings.realm
    if pick and realms[pick] then return pick end
    local cur = self:CurrentRealmKey()
    if cur and realms[cur] then return cur end
    local list = self:RealmList()
    if list[1] then return list[1].key end
    return cur
end

function Ledger:ForgetRealm(key)
    if not key or not ML.db.realms[key] then return end
    ML.db.realms[key] = nil
    self.index[key] = nil
    self.hist, self.scanHist = nil, nil
    if ML.db.settings.realm == key then ML.db.settings.realm = nil end
    ns.Print(("history for %s forgotten. Auctionator's own data was not touched."):format(key))
    ML:RequestUIRefresh()
end

-------------------------------------------------------------------------------
-- Turning one Auctionator entry into day records
-------------------------------------------------------------------------------
local function Lookup(t, day)
    if type(t) ~= "table" then return nil end
    return Num(t[tostring(day)]) or Num(t[day])
end

-- Records for days after "after" (all when nil), sorted; nil when there are none
local function Points(rec, after)
    local h = rec.h
    if type(h) ~= "table" then return nil end
    local days = {}
    for k, hi in pairs(h) do
        local d = tonumber(k)
        hi = Num(hi)
        if d and hi and hi > 0 and (not after or d > after) then days[#days + 1] = d end
    end
    if #days == 0 then return nil end
    table.sort(days)
    local P = Codec.NewList()
    for i = 1, #days do
        local d = days[i]
        if d ~= days[i - 1] then
            local hi = Lookup(h, d)
            local lo = Lookup(rec.l, d) or hi
            if lo <= 0 then lo = hi end
            if lo > hi then lo, hi = hi, lo end
            local q = Lookup(rec.a, d) or 0
            if q < 0 then q = 0 end
            Codec.Push(P, d, floor(lo), floor(hi), floor(q))
        end
    end
    return P
end
Ledger.Points = Points

-------------------------------------------------------------------------------
-- Recording
-------------------------------------------------------------------------------
Ledger.queue = {}            -- realms waiting to be recorded (imports)

function Ledger:ScheduleRecord(delay, reason, silent)
    if not ML.db.settings.autoRecord and reason ~= "login" then return end
    if self.recordTimer then self.recordTimer:Cancel() end
    self.recordTimer = C_Timer.NewTimer(delay, function()
        self.recordTimer = nil
        self:RecordNow(reason, silent)
    end)
end

function Ledger:RecordNow(reason, silent)
    local src, key, err = self:LiveSource()
    if src and key and self:AuctionatorShared(key) then
        self.status = "Recording from MendeLedger's own scans: Auctionator keeps one price list for several of your auction houses."
        if not self.sharedNoticed then
            self.sharedNoticed = true
            ns.Print(("Auctionator keeps one price list for several of your auction houses, so MendeLedger records %s from its own scans only. Every scan made while MendeLedger is enabled counts. (Auctionator 350 and later keep them apart.)"):format(self:RealmName(key)))
        end
        ML:RequestUIRefresh()
        return false
    end
    if src and not key then
        self.status = "Not recording: MendeLedger doesn't know which auction house this character uses."
        self:RealmUnknownNotice()
        ML:RequestUIRefresh()
        return false
    end
    if not src then
        self.status = err
        if not silent then ns.Print(err) end
        ML:RequestUIRefresh()
        return false
    end
    self:Enqueue({ key = key, src = src, reason = reason, silent = silent, current = true })
    return true
end

-- /mendel import: every Auctionator price list, all days (merging is idempotent),
-- each into the auction house(s) it belongs to. Nothing is filed by realm.
function Ledger:ImportAll(quiet)
    local root = rawget(_G, "AUCTIONATOR_PRICE_DATABASE")
    if type(root) ~= "table" then ns.Print("Auctionator isn't loaded, so there is nothing to import.") return end
    local liveSrc, liveKey = self:LiveSource()
    local liveList = self:AuctionatorKey()
    local region = (liveKey and liveKey:match(AH)) or self:Region()
    local lists, failed, skipped, unplaced = 0, 0, 0, 0
    for listKey, v in pairs(root) do
        if type(listKey) == "string" and listKey ~= "__dbversion" then
            local targets = {}
            if liveKey and listKey == liveList then
                targets[liveKey] = true                             -- this character's own list
            elseif listKey == "" then
                -- Auctionator's list for everything after the hotfix (before 350):
                -- only when exactly one of this account's auction houses used it
                local owners = {}
                for hk, h in pairs(ML.db.houses) do
                    if type(h.aKeys) == "table" and h.aKeys[""] then owners[#owners + 1] = hk end
                end
                if #owners == 1 then targets[owners[1]] = true
                elseif #owners == 0 and liveKey and not self:AuctionatorShared(liveKey) then targets[liveKey] = true
                elseif #owners == 0 and not liveKey then skipped = skipped + 1 end
            else
                local ruleset, faction = Ledger.ParseAuctionatorList(listKey)
                if ruleset then
                    -- Auctionator 350+'s "<ruleset> <faction>" lists: that auction house in this region
                    if region then targets[region .. "-" .. ruleset .. "-" .. faction] = true end
                else
                    -- a list Auctionator filed under a realm name before Forever hid
                    -- realms: into the account's auction houses with its region and ruleset
                    local r, rs = Ledger.ParseOldKey(listKey)
                    if r and rs then
                        for hk in pairs(ML.db.houses) do
                            local hr, hrs = hk:match(AH)
                            if hr == r and hrs == rs then targets[hk] = true end
                        end
                        if liveKey then
                            local lr, lrs = liveKey:match(AH)
                            if lr == r and lrs == rs then targets[liveKey] = true end
                        end
                    end
                    if not next(targets) then unplaced = unplaced + 1 end
                end
            end
            if next(targets) then
                local src
                if liveKey and listKey == liveList and liveSrc then src = liveSrc
                elseif type(v) == "table" then src = v
                else src = self:DecodeCBOR(v) end
                if src then
                    lists = lists + 1
                    for target in pairs(targets) do
                        self:Enqueue({ key = target, src = src, reason = "import", full = true,
                                       silent = quiet and true or false, current = target == liveKey })
                    end
                else
                    failed = failed + 1
                end
            end
        end
    end
    if skipped > 0 then self:RealmUnknownNotice() end
    if quiet then return end
    if lists == 0 and failed == 0 then
        if skipped == 0 then ns.Print("Auctionator has no prices saved that MendeLedger can place yet.") end
        return
    end
    ns.Print(("importing %d price list%s from Auctionator%s%s."):format(lists, lists == 1 and "" or "s",
        failed > 0 and (" (%d couldn't be unpacked on this client)"):format(failed) or "",
        unplaced > 0 and (" (%d older list%s waits for a character of its auction house)"):format(unplaced, unplaced == 1 and "" or "s") or ""))
end

function Ledger:Enqueue(req)
    for _, q in ipairs(self.queue) do
        if q.key == req.key and q.src == req.src then
            q.src, q.full = req.src, q.full or req.full
            q.silent = q.silent and req.silent
            return
        end
    end
    if self.harvest and self.harvest.key == req.key and not req.full then
        self.harvest.again = true           -- record once more when this pass ends
        return
    end
    self.queue[#self.queue + 1] = req
    if not self.harvest then self:NextHarvest() end
end

function Ledger:NextHarvest()
    local req = table.remove(self.queue, 1)
    if not req then return end
    local realm = self:Realm(req.key, true)
    local today = ns.Today()
    local after = (not req.full) and realm.settled or nil
    local keys = {}
    for k, v in pairs(req.src) do
        if type(k) == "string" and (type(v) == "table" or type(v) == "string") then keys[#keys + 1] = k end
    end
    local job = {
        name = "record", label = "recording " .. self:RealmName(req.key), key = req.key, req = req,
        keys = keys, i = 1, updated = 0, added = 0, newItems = 0, today = today,
    }
    local src, items = req.src, realm.items
    function job:Step(deadline)
        local compress = ML.db.settings.compress
        local list, n = self.keys, #self.keys
        while self.i <= n do
            local k = list[self.i]
            self.i = self.i + 1
            local rec = src[k]
            if type(rec) == "string" then rec = Ledger:DecodeCBOR(rec) end
            if type(rec) == "table" then
                local P = Points(rec, after)
                if P then
                    local old = items[k]
                    local m = Num(rec.m)
                    local new, added = Codec.Merge(old, P, (m and m > 0) and floor(m) or nil, compress, today)
                    if new and new ~= old then
                        items[k] = new
                        self.updated = self.updated + 1
                        self.added = self.added + added
                        if not old then self.newItems = self.newItems + 1 end
                        Ledger:IndexPut(self.key, k, new)
                    end
                end
            end
            if self.i % 4 == 0 and ns.Clock() >= deadline then return false end
        end
        return true
    end
    function job:Progress() return self.i - 1, #self.keys end
    function job:OnDone() Ledger:HarvestDone(self) end
    self.harvest = job
    ns.StartJob(job)
end

function Ledger:HarvestDone(job)
    local realm = self:Realm(job.key, true)
    if not job.failed then
        realm.settled = math.min(job.today, ML.sessionDay or job.today) - 1
        realm.lastRecord = time()
        realm.lastAdded, realm.lastUpdated = job.added, job.updated
    end
    self.harvest = nil
    if self.hist and self.hist.realm == job.key then self.hist = nil end
    local s = ML.db.settings
    if job.failed then
        self.status = "The last recording stopped with an error."
    elseif job.added > 0 then
        self.status = ("Added %s daily price%s across %s item%s%s."):format(ns.Commas(job.added), job.added == 1 and "" or "s",
            ns.Commas(job.updated), job.updated == 1 and "" or "s",
            job.newItems > 0 and (" (%s new)"):format(ns.Commas(job.newItems)) or "")
    elseif job.updated > 0 then
        self.status = ("Updated today's prices for %s item%s."):format(ns.Commas(job.updated), job.updated == 1 and "" or "s")
    else
        self.status = "Up to date: Auctionator had nothing newer."
    end
    if not job.req.silent or (job.added > 0 and s.announce) then
        ns.Print(("%s: %s"):format(self:RealmName(job.key), self.status))
    end
    if s.keepDays > 0 then self:Prune(job.key) end
    self:StatsChanged(job.key)
    if job.again then self:RecordNow(job.req.reason, true) end
    self:NextHarvest()
    ML:RequestUIRefresh(nil, true)
end

-------------------------------------------------------------------------------
-- Jobs over every item of a realm: stats, pruning, repacking, indexing
-------------------------------------------------------------------------------
-- store: "items" (daily ledger, default) or "scans" (scan detail)
local function StoreOf(realm, store)
    if store == "scans" then return realm.scans and realm.scans.items end
    return realm.items
end

local function ItemJob(name, label, realmKey, perItem, onDone, store)
    local realm = Ledger:Realm(realmKey)
    local items = realm and StoreOf(realm, store)
    if not items then return nil end
    local keys = {}
    for k in pairs(items) do keys[#keys + 1] = k end
    local job = { name = name, label = label, key = realmKey, keys = keys, i = 1 }
    function job:Step(deadline)
        local list, n = self.keys, #self.keys
        while self.i <= n do
            local k = list[self.i]
            self.i = self.i + 1
            local s = items[k]
            if s then perItem(self, k, s, items) end
            if self.i % 24 == 0 and ns.Clock() >= deadline then return false end
        end
        return true
    end
    function job:Progress() return self.i - 1, #self.keys end
    job.OnDone = onDone
    return ns.StartJob(job)
end

-- Storage figures are only shown on the Options tab, and measuring them reads
-- every item history (100,000+ strings on a busy account). So recordings and
-- scans only mark them out of date; they're measured again when the Options
-- tab shows them, or at most every 10 minutes.
local STATS_EVERY = 600
Ledger.statsAt = {}

function Ledger:StatsChanged(realmKey, scans)
    local realm = self:Realm(realmKey)
    if not realm then return end
    realm.statsDirty = true
    if scans then realm.scanStatsDirty = true end
    self:MaybeRefreshStats(realmKey)
end

function Ledger:MaybeRefreshStats(realmKey, now)
    local realm = self:Realm(realmKey)
    if not realm then return end
    if not now and time() - (self.statsAt[realmKey] or 0) < STATS_EVERY then return end
    self.statsAt[realmKey] = time()
    if (realm.statsDirty or not realm.stats) and not ns.FindJob("stats") then
        realm.statsDirty = nil
        self:RefreshStats(realmKey)
    end
    if realm.scans and (realm.scanStatsDirty or not realm.scanStats) and not ns.FindJob("scanStats") then
        realm.scanStatsDirty = nil
        self:RefreshScanStats(realmKey)
    end
end

function Ledger:RefreshStats(realmKey)
    local st = { items = 0, records = 0, bytes = 0, unpacked = 0, compressed = 0, rawSealed = 0 }
    ItemJob("stats", "measuring storage", realmKey, function(_, _, s)
        local m, _, count, first, last, _, comp, rawSealed, unpacked = Codec.Summary(s)
        if not m then return end
        st.items = st.items + 1
        st.records = st.records + count
        st.bytes = st.bytes + #s
        st.unpacked = st.unpacked + unpacked
        st.compressed = st.compressed + comp
        st.rawSealed = st.rawSealed + rawSealed
        if first and (not st.first or first < st.first) then st.first = first end
        if last and (not st.last or last > st.last) then st.last = last end
    end, function()
        local realm = Ledger:Realm(realmKey)
        if realm then realm.stats = st end
        ML:RequestUIRefresh(nil, true)
    end)
end

-- Keep-history limit. Whole sealed blocks only, so sealed data isn't rewritten daily.
function Ledger:Prune(realmKey)
    local keep = ML.db.settings.keepDays
    local realm = self:Realm(realmKey)
    if keep <= 0 or not realm then return end
    local today = ns.Today()
    if realm.prunedOn == today and realm.prunedKeep == keep then return end
    local cutoff = today - keep + 1
    local removed, dropped = 0, 0
    ItemJob("prune", "removing old history", realmKey, function(_, k, s, items)
        local new, n = Codec.Prune(s, cutoff)
        if n > 0 then
            removed = removed + n
            items[k] = new
            if new then Ledger:IndexPut(realmKey, k, new) else dropped = dropped + 1; Ledger:IndexRemove(realmKey, k) end
        end
    end, function()
        realm.prunedOn, realm.prunedKeep = today, keep
        if removed > 0 then
            ns.Print(("%s: removed %s daily prices older than %d days%s."):format(Ledger:RealmName(realmKey),
                ns.Commas(removed), keep, dropped > 0 and (" (%s items emptied)"):format(ns.Commas(dropped)) or ""))
            Ledger.hist = nil
            Ledger:RefreshStats(realmKey)
        end
    end)
end

-- Matches every realm's sealed blocks to the compression setting
function Ledger:Repack(quiet)
    local compress = ML.db.settings.compress and self:CanCompress()
    if ML.db.settings.compress and not self:CanCompress() then
        ns.Print("this client has no Deflate, so sealed history stays uncompressed.")
        return
    end
    local changed = 0
    local keys = {}
    for key in pairs(ML.db.realms) do keys[#keys + 1] = key end
    local function Repacker(_, k, s, items)
        local new, did = Codec.Repack(s, compress)
        if did then items[k] = new; changed = changed + 1 end
    end
    for i, key in ipairs(keys) do
        ItemJob("repack", "repacking " .. self:RealmName(key), key, Repacker, function() Ledger:RefreshStats(key) end)
        local last = i == #keys
        local job = ItemJob("repack", "repacking scan detail", key, Repacker, function()
            Ledger.scanHist = nil
            Ledger:RefreshScanStats(key)
            if last and not quiet then
                ns.Print(("repacked %s item histories (%s)."):format(ns.Commas(changed), compress and "compressed where it saves 10% or more" or "uncompressed"))
            end
        end, "scans")
        if not job and last and not quiet then
            ns.Print(("repacked %s item histories."):format(ns.Commas(changed)))
        end
    end
    if #keys == 0 and not quiet then ns.Print("the ledger is empty.") end
end

function Ledger:PrintStats()
    local key = self:ShownRealm()
    local realm = key and self:Realm(key)
    if not realm or not realm.stats then ns.Print("nothing recorded yet.") return end
    local st = realm.stats
    ns.Print(("%s: %s items, %s daily prices from %s to %s"):format(self:RealmName(key), ns.Commas(st.items),
        ns.Commas(st.records), ns.DayDate(st.first), ns.DayDate(st.last)))
    print(("  stored in %s (%.1f bytes per daily price); as Lua tables it would be about %s"):format(
        ns.Bytes(st.bytes), st.records > 0 and st.bytes / st.records or 0, ns.Bytes(st.records * 50)))
    print(("  sealed blocks: %d compressed, %d stored as is; compression saved %s"):format(
        st.compressed, st.rawSealed, ns.Bytes(st.unpacked - st.bytes)))
    local ss = realm.scanStats
    if ss and ss.scans > 0 then
        print(("  scan detail: %s scans (%s full) from %s to %s, %s records in %s"):format(ns.Commas(ss.scans), ns.Commas(ss.full),
            ns.WhenLabel(ss.first), ns.WhenLabel(ss.last), ns.Commas(ss.records), ns.Bytes(ss.bytes)))
    end
end

-------------------------------------------------------------------------------
-- Item names: cached in MendeLedgerDB, loaded from the server a few at a time
-------------------------------------------------------------------------------
local urgent, normal = { head = 1, tail = 0 }, { head = 1, tail = 0 }
local queued, queuedUrgent, pending, failed, forced = {}, {}, {}, {}, {}
local outstanding = 0
local nameTicker

function Ledger:CachedName(id)
    local c = ML.db.names[id]
    if type(c) == "string" and #c > 1 then return c:sub(2), tonumber(c:sub(1, 1)) or 1 end
    return nil
end

local function StoreName(id, name, quality)
    quality = Num(quality) or 1
    if quality < 0 or quality > 9 then quality = 1 end
    ML.db.names[id] = floor(quality) .. name
end

-- name, quality; nil (and asks the server) when the client doesn't have it yet
function Ledger:ItemName(id)
    local name, q = self:CachedName(id)
    if name then return name, q end
    if type(id) ~= "number" then return nil end
    local n
    if C_Item and C_Item.GetItemNameByID then n = Text((ns.SafeCall(C_Item.GetItemNameByID, id))) end   -- RETEST
    if not n and C_Item and C_Item.GetItemInfo then n = Text((ns.SafeCall(C_Item.GetItemInfo, id))) end
    if n then
        local quality = C_Item and C_Item.GetItemQualityByID and ns.SafeCall(C_Item.GetItemQualityByID, id)
        StoreName(id, n, quality)
        return n, Num(quality) or 1
    end
    self:QueueName(id)
    return nil
end

function Ledger:PetName(species)
    local key = "p:" .. species
    local name = self:CachedName(key)
    if name then return name end
    if C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
        local n = Text((ns.SafeCall(C_PetJournal.GetPetInfoBySpeciesID, species)))
        if n then StoreName(key, n, 1); return n end
    end
    return nil
end

local function PushId(list, id)
    list.tail = list.tail + 1
    list[list.tail] = id
end

local function Pop(list)
    if list.head > list.tail then
        list.head, list.tail = 1, 0
        return nil
    end
    local id = list[list.head]
    list[list.head] = nil
    list.head = list.head + 1
    return id
end

local function QueueEmpty(list)
    return list.head > list.tail
end

local function NameTick()
    local now = GetTime()
    for id, t in pairs(pending) do
        if now - t > 15 then pending[id] = nil; outstanding = outstanding - 1; failed[id] = true end
    end
    local sent = 0
    while sent < 25 and outstanding < 80 do
        local id = Pop(urgent) or Pop(normal)
        if not id then break end
        queued[id], queuedUrgent[id] = nil, nil
        if not pending[id] and not failed[id] and (forced[id] or not Ledger:CachedName(id)) then
            pending[id] = now
            outstanding = outstanding + 1
            sent = sent + 1
            if C_Item and C_Item.RequestLoadItemDataByID then        -- RETEST
                ns.SafeCall(C_Item.RequestLoadItemDataByID, id)
            elseif C_Item and C_Item.GetItemInfo then
                ns.SafeCall(C_Item.GetItemInfo, id)               -- also asks the server
            end
        end
    end
    if outstanding <= 0 and QueueEmpty(urgent) and QueueEmpty(normal) and nameTicker then
        nameTicker:Cancel()
        nameTicker = nil
        outstanding = 0
    end
end

-- force: load the item even if its name is already cached (tooltips need the item itself)
function Ledger:QueueName(id, isUrgent, force)
    if type(id) ~= "number" or failed[id] or pending[id] then return end
    if force then forced[id] = true end
    if isUrgent then
        if queuedUrgent[id] then return end
        queuedUrgent[id] = true
    elseif queued[id] then
        return
    end
    queued[id] = true
    PushId(isUrgent and urgent or normal, id)
    if not nameTicker then nameTicker = C_Timer.NewTicker(0.2, NameTick) end
end

local function OnItemLoaded(itemID, success)
    itemID = Num(itemID)
    if not itemID or not pending[itemID] then return end
    pending[itemID] = nil
    outstanding = outstanding - 1
    local wasForced = forced[itemID]
    forced[itemID] = nil
    if success == false then
        failed[itemID] = true
        Ledger:TooltipArrived(itemID, false)
        Ledger:FactsArrived(itemID, false)
        return
    end
    if Ledger:ItemName(itemID) then
        Ledger:NameArrived(itemID)
    end
    if wasForced then
        Ledger:TooltipArrived(itemID, true)
        Ledger:FactsArrived(itemID, true)
    end
end

-------------------------------------------------------------------------------
-- Item facts for the profit sorts, read once the item is loaded and kept for
-- the session: from C_Item.GetItemInfo the vendor price (value 11: what a
-- merchant pays for one, 0 = can't be sold), quality and item level; from
-- C_Item.GetItemInfoInstant the class, subclass and slot. Auctionator's
-- AUCTIONATOR_VENDOR_PRICE_CACHE is not used: it holds what merchants charge
-- (recorded for crafting costs), not what they pay.
-------------------------------------------------------------------------------
Ledger.facts = {}                 -- [itemID] = { sell, quality, itemLevel, classID, subclassID, equipLoc }
local factsWanted = {}

local function ReadFacts(id)
    if not (C_Item and C_Item.GetItemInfo) then return nil end
    local info = { ns.SafeCall(C_Item.GetItemInfo, id) }                    -- RETEST: sellPrice is value 11
    if not Text(info[1]) then return nil end                              -- not loaded yet
    local sell = Num(info[11]) or 0
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or rawget(_G, "GetItemInfoInstant")
    local inst = { ns.SafeCall(getInstant, id) }
    return {
        sell       = sell > 0 and floor(sell) or 0,
        quality    = Num(info[3]),
        itemLevel  = Num(info[4]),
        equipLoc   = Text(inst[4]) or Text(info[9]) or "",
        classID    = Num(inst[6]) or Num(info[12]),
        subclassID = Num(inst[7]) or Num(info[13]),
    }
end

-- The item's facts, or nil while it loads (it's requested once through the
-- same throttled queue as names and tooltips)
function Ledger:ItemFacts(id)
    if type(id) ~= "number" then return nil end
    local f = self.facts[id]
    if f then return f end
    f = ReadFacts(id)
    if f then
        self.facts[id] = f
        return f
    end
    if not factsWanted[id] then
        factsWanted[id] = true
        self:QueueName(id, false, true)
    end
    return nil
end

function Ledger:FactsArrived(id, ok)
    if not factsWanted[id] then return end
    factsWanted[id] = nil
    if not ok then return end
    local f = ReadFacts(id)
    if f then
        self.facts[id] = f
        Ledger.factsVersion = (Ledger.factsVersion or 0) + 1
        local sort = ML.db.settings.sort
        if sort == "profit" or sort == "deprofit" then ML:RequestUIRefresh(nil, true) end
    end
end

-- Copper a vendor pays for one of the item, 0 if it can't be sold, nil while unknown
function Ledger:VendorPrice(id)
    local f = self:ItemFacts(id)
    return f and f.sell or nil
end

-- Profit on one item from buying it at its latest lowest buyout and selling it
-- to a vendor. Returns profit (nil when unknown or the item can't be vendored)
-- and the vendor price (0 = can't be sold, nil = not known yet).
function Ledger:VendorProfit(e)
    if not e or e.kind == "pet" or not e.id then return nil, nil end
    local v = self:VendorPrice(e.id)
    if not v or v <= 0 or not e.m or e.m <= 0 then return nil, v end
    return v - e.m, v
end

-------------------------------------------------------------------------------
-- Disenchant profit: the expected disenchant value (Disenchant.lua) minus the
-- item's latest lowest buyout. Material prices are the materials' latest
-- lowest buyouts in the same realm's ledger, so an imported realm uses its
-- own prices.
-------------------------------------------------------------------------------
local DE = ns.Disenchant
do
    local classes = Enum and Enum.ItemClass                                -- RETEST
    local armorSub, weaponSub = Enum and Enum.ItemArmorSubclass, Enum and Enum.ItemWeaponSubclass
    DE.CLASS_WEAPON = (classes and Num(classes.Weapon)) or 2
    DE.CLASS_ARMOR = (classes and Num(classes.Armor)) or 4
    DE.BLOCKED_SUBCLASS = {
        [DE.CLASS_ARMOR] = { [(armorSub and Num(armorSub.Cosmetic)) or 5] = true },
        [DE.CLASS_WEAPON] = { [(weaponSub and Num(weaponSub.Fishingpole)) or 20] = true },
    }
end
local NOT_DE_TEXT = Text(rawget(_G, "ITEM_DISENCHANT_NOT_DISENCHANTABLE"))  -- RETEST: "Cannot be disenchanted"
NOT_DE_TEXT = NOT_DE_TEXT and NOT_DE_TEXT:lower()

-- One unit of a material in a realm: its latest lowest buyout in the ledger.
-- memo (optional) caches lookups for one pass over the list.
function Ledger:MaterialPrice(realmKey, itemID, memo)
    if memo and memo[itemID] ~= nil then return memo[itemID] or nil end
    local key, price = tostring(itemID), nil
    local idx = realmKey and self.index[realmKey]
    local e = idx and idx.byKey[key]
    if e then
        price = e.m
    else
        local realm = realmKey and self:Realm(realmKey)
        local s = realm and realm.items[key]
        if s then price = Codec.Summary(s) end
    end
    if memo then memo[itemID] = price or false end
    return price
end

-- Returns profit, value, state, partial, estimated
--   state "ok"       value = expected disenchant value; profit = value - latest lowest buyout
--         "loading"  the item's facts aren't known yet
--         "noprice"  none of its materials has a price in this realm yet
--         "nodata"   gear whose item level is outside the disenchant tables
--         "cannot"   gear that can't be disenchanted (or its tooltip says so)
--         nil        not uncommon, rare or epic armor or weapons
--   partial: some possible material has no price, so the value is too low
function Ledger:DisenchantProfit(realmKey, e, memo)
    if not e or e.kind == "pet" or not e.id then return nil end
    local f = self:ItemFacts(e.id)
    if not f then return nil, nil, "loading" end
    local itemLevel = (e.kind == "gear" and tonumber(e.ilvl)) or f.itemLevel
    local tip = self.tips[e.id]
    local refuses = NOT_DE_TEXT ~= nil and tip ~= nil and tip:find(NOT_DE_TEXT, 1, true) ~= nil
    local result = DE.Evaluate({ id = e.id, quality = f.quality, itemLevel = itemLevel, classID = f.classID,
                                 subclassID = f.subclassID, equipLoc = f.equipLoc }, refuses)
    if not result then return nil end
    if result.status ~= "ok" then return nil, nil, result.status end
    local value, partial = DE.ExpectedValue(result.outcomes, function(id) return self:MaterialPrice(realmKey, id, memo) end)
    if not value then return nil, nil, "noprice", partial, result.estimated end
    if not e.m or e.m <= 0 then return nil, value, "ok", partial, result.estimated end
    return value - e.m, value, "ok", partial, result.estimated
end

-------------------------------------------------------------------------------
-- Tooltip text for searching: kept for the session only (not saved), keyed by
-- item ID and shared by every realm. Read with C_TooltipInfo, which builds a
-- tooltip's text without showing anything; a hidden tooltip is the fallback.
-- Reading stops at the "Sell Price" line, so lines other addons append after
-- it (Auctionator's Vendor and Auction prices, for example) never match.
-------------------------------------------------------------------------------
Ledger.tips = {}                  -- [itemID] = lower-case tooltip text, one line per row
local tipWanted, tipFailed = {}, {}
local scanTip

local SELL_PRICE_TEXT = Text(rawget(_G, "SELL_PRICE"))            -- RETEST: "Sell Price"
local RETRIEVING_TEXT = Text(rawget(_G, "RETRIEVING_ITEM_INFO"))  -- RETEST: "Retrieving item information"

local function Clean(v)
    v = Text(v)
    if not v then return nil end
    v = v:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", "")
         :gsub("|H.-|h(.-)|h", "%1"):gsub("|n", " ")
    v = ns.Trim(v)
    return v ~= "" and v or nil
end

local function StartsWith(text, prefix)
    return prefix ~= nil and text:sub(1, #prefix) == prefix
end

-- The text lines of an item's tooltip, or nil when the game hasn't loaded the item yet
local function TooltipLines(id)
    local out = {}
    local function Add(left, right)
        if left then out[#out + 1] = left end
        if right then out[#out + 1] = right end
    end
    if C_TooltipInfo and C_TooltipInfo.GetItemByID then                    -- RETEST
        local data = ns.SafeCall(C_TooltipInfo.GetItemByID, id)
        if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
        local types = Enum and Enum.TooltipDataLineType
        local sellType = types and types.SellPrice                          -- RETEST
        for _, line in ipairs(data.lines) do
            if type(line) == "table" then
                if sellType and Num(line.type) == sellType then break end
                local left, right = Clean(line.leftText), Clean(line.rightText)
                if left and RETRIEVING_TEXT and left == RETRIEVING_TEXT then return nil end
                if left and StartsWith(left, SELL_PRICE_TEXT) then break end
                Add(left, right)
            end
        end
        return #out > 0 and out or nil
    end
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "MendeLedgerScanTooltip", UIParent, "GameTooltipTemplate")   -- RETEST
    end
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    if not pcall(scanTip.SetItemByID, scanTip, id) then scanTip:Hide() return nil end
    for i = 1, scanTip:NumLines() or 0 do
        local lfs, rfs = _G["MendeLedgerScanTooltipTextLeft" .. i], _G["MendeLedgerScanTooltipTextRight" .. i]
        local left = lfs and Clean(lfs:GetText())
        local right = rfs and rfs:IsShown() and Clean(rfs:GetText()) or nil
        if left and RETRIEVING_TEXT and left == RETRIEVING_TEXT then scanTip:Hide() return nil end
        if left and StartsWith(left, SELL_PRICE_TEXT) then break end
        Add(left, right)
    end
    scanTip:Hide()
    return #out > 0 and out or nil
end

-- Reads one item's tooltip into Ledger.tips. When the item isn't loaded yet it
-- asks the server once and tries again when the item arrives.
function Ledger:ReadTooltip(id, final)
    if self.tips[id] or tipFailed[id] then return self.tips[id] ~= nil end
    if not final and C_Item and C_Item.IsItemDataCachedByID then           -- RETEST
        local cached = ns.SafeCall(C_Item.IsItemDataCachedByID, id)
        if not ns.IsSecret(cached) and cached == false then
            tipWanted[id] = true
            self:QueueName(id, false, true)
            return false
        end
    end
    local lines = TooltipLines(id)
    if not lines then
        if final then tipFailed[id] = true return false end
        tipWanted[id] = true
        self:QueueName(id, false, true)
        return false
    end
    tipWanted[id] = nil
    self.tips[id] = table.concat(lines, "\n"):lower()
    return true
end

function Ledger:TooltipArrived(id, ok)
    if not tipWanted[id] then return end
    tipWanted[id] = nil
    if not ok then tipFailed[id] = true return end
    if self:ReadTooltip(id, true) then
        for _, idx in pairs(self.index) do
            if idx.byId[id] then idx.version = idx.version + 1 end
        end
        if ML.searchActive then ML:RequestUIRefresh(nil, true) end
    end
end

-- Reads the tooltips of every item in a realm's index that doesn't have one yet
function Ledger:EnsureTooltips(realmKey, foreground)
    if not ML.db.settings.searchTooltips or ns.FindJob("tooltips") then return end
    local idx = realmKey and self.index[realmKey]
    if not idx or not idx.ready then return end
    local ids = {}
    for id in pairs(idx.byId) do
        if not self.tips[id] and not tipWanted[id] and not tipFailed[id] then ids[#ids + 1] = id end
    end
    if #ids == 0 then return end
    table.sort(ids)
    local job = { name = "tooltips", label = "reading item tooltips", ids = ids, i = 1, foreground = foreground }
    function job:Step(deadline)
        local list, n = self.ids, #self.ids
        while self.i <= n do
            Ledger:ReadTooltip(list[self.i])
            self.i = self.i + 1
            if self.i % 2 == 0 and ns.Clock() >= deadline then return false end
        end
        return true
    end
    function job:Progress() return self.i - 1, #self.ids end
    function job:OnDone()
        idx.version = idx.version + 1
        ML:RequestUIRefresh(nil, true)
    end
    ns.StartJob(job)
end

function Ledger:TooltipProgress()
    local job = ns.FindJob("tooltips")
    if job then return job:Progress() end
    return nil
end

-- Search terms: words, or "a quoted phrase"; every term must match
function Ledger.ParseSearch(text)
    local terms = {}
    text = ns.Trim(text or ""):lower()
    text = text:gsub('"([^"]*)"', function(phrase)
        phrase = ns.Trim(phrase)
        if phrase ~= "" then terms[#terms + 1] = phrase end
        return " "
    end)
    for word in text:gmatch("%S+") do
        word = word:gsub('"', "")
        if word ~= "" then terms[#terms + 1] = word end
    end
    return terms
end

-- True when every term is in the item's name, its type/subtype/slot, or
-- (with useTips) its tooltip. A search that is just a number matches item IDs
-- and names only, so "51" doesn't list every item with a 51 in its tooltip.
function Ledger:Matches(e, terms, useTips)
    if #terms == 1 and terms[1]:match("^%d+$") then
        return e.id == tonumber(terms[1]) or (e.lname ~= nil and e.lname:find(terms[1], 1, true) ~= nil)
    end
    local tip = useTips and e.id and e.kind ~= "pet" and self.tips[e.id] or nil
    for _, term in ipairs(terms) do
        local found = (e.lname and e.lname:find(term, 1, true))
            or (e.kinds and e.kinds:find(term, 1, true))
            or (tip and tip:find(term, 1, true))
        if not found then return false end
    end
    return true
end

-------------------------------------------------------------------------------
-- In-memory index for the item list (built in the background per realm)
-------------------------------------------------------------------------------
Ledger.index = {}

local function ParseKey(key)
    local id = key:match("^(%d+)$")
    if id then return tonumber(id), nil, "item" end
    local gid, lvl = key:match("^g:(%d+):(%d+)$")
    if gid then return tonumber(gid), tonumber(lvl), "gear" end
    gid, lvl = key:match("^gr:(%d+):(.+)$")
    if gid then return tonumber(gid), lvl, "suffix" end          -- e.g. "gr:15115:of the Bear"
    local sp = key:match("^p:(%d+)$")
    if sp then return tonumber(sp), nil, "pet" end
    return nil, nil, "other"
end
Ledger.ParseKey = ParseKey

function Ledger:FillNames(e)
    if e.kind == "pet" then
        e.name, e.quality = self:PetName(e.id), 1
    elseif e.id then
        e.name, e.quality = self:ItemName(e.id)
    end
    local label = e.name
    if label and e.kind == "gear" and e.ilvl then label = ("%s (%s)"):format(label, tostring(e.ilvl)) end
    if label and e.kind == "suffix" and e.suffix then label = label .. " " .. e.suffix end
    e.label = label
    e.lname = label and label:lower() or nil
    e.sn = e.lname or ("~" .. e.key)                 -- sort key: unnamed items last
end

-- Type, subtype, slot, icon and class of an item, asked once per item ID and
-- session (the 42,000+ random-suffix keys of a busy account share 7,500 items)
Ledger.instant = {}
function Ledger:InstantInfo(id)
    local info = self.instant[id]
    if info then return info end
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or rawget(_G, "GetItemInfoInstant")   -- RETEST
    local _, itemType, itemSubType, equipLoc, icon, classID = ns.SafeCall(getInstant, id)
    info = { typeName = Text(itemType), subName = Text(itemSubType), icon = Num(icon), cls = Num(classID) }
    equipLoc = Text(equipLoc)
    info.slotName = equipLoc and Text(rawget(_G, equipLoc)) or nil   -- "INVTYPE_LEGS" -> "Legs"
    local words = {}
    for _, w in ipairs({ info.typeName or "", info.subName or "", info.slotName or "" }) do
        if w ~= "" then words[#words + 1] = w end
    end
    info.kinds = table.concat(words, "\n"):lower()
    self.instant[id] = info
    return info
end

function Ledger:MakeEntry(key, s, e)
    local m, ref7, count, first, last = Codec.Summary(s)
    if not m then return nil end
    if not e then
        e = { key = key }
        local extra
        e.id, extra, e.kind = ParseKey(key)
        if e.kind == "suffix" then e.suffix = extra else e.ilvl = extra end
        if e.kind == "pet" then
            e.typeName, e.cls = "Battle Pets", 17
            if C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
                local _, icon = ns.SafeCall(C_PetJournal.GetPetInfoBySpeciesID, e.id)
                e.icon = Num(icon)
            end
        elseif e.id then
            local info = Ledger:InstantInfo(e.id)
            e.typeName, e.subName, e.icon, e.cls, e.slotName, e.kinds = info.typeName, info.subName, info.icon, info.cls, info.slotName, info.kinds
        end
        if e.kind == "pet" then e.kinds = "battle pets\nbattle pet" end
        self:FillNames(e)
    end
    e.m, e.ref7, e.count, e.first, e.last = m, ref7, count, first, last
    e.change = (ref7 and ref7 > 0 and m > 0) and (m - ref7) / ref7 or nil
    return e
end

-- The index for a realm; starts building it in the background when needed
function Ledger:GetIndex(realmKey)
    if not realmKey then return nil end
    local idx = self.index[realmKey]
    if idx then return idx end
    idx = { byKey = {}, byId = {}, ready = false, version = 0, count = 0, nameVersion = 0 }
    self.index[realmKey] = idx
    local realm = self:Realm(realmKey)
    if not realm then idx.ready = true return idx end
    local job = ItemJob("index", "indexing " .. self:RealmName(realmKey), realmKey, function(_, k, s)
        if not idx.byKey[k] then Ledger:IndexPut(realmKey, k, s) end
    end, function()
        idx.ready = true
        ML:RequestUIRefresh()
    end)
    if job then job.foreground = true else idx.ready = true end
    return idx
end

function Ledger:IndexPut(realmKey, key, s)
    local idx = self.index[realmKey]
    if not idx then return end
    local old = idx.byKey[key]
    local e = self:MakeEntry(key, s, old)
    if not e then return end
    if not old then
        idx.byKey[key] = e
        idx.count = (idx.count or 0) + 1
        idx.nameVersion = (idx.nameVersion or 0) + 1  -- entries added: the name order changes
        if e.id and e.kind ~= "pet" then
            local list = idx.byId[e.id]
            if not list then list = {}; idx.byId[e.id] = list end
            list[#list + 1] = e
        end
    end
    idx.version = idx.version + 1
end

function Ledger:IndexRemove(realmKey, key)
    local idx = self.index[realmKey]
    if not idx or not idx.byKey[key] then return end
    local e = idx.byKey[key]
    idx.byKey[key] = nil
    idx.count = math.max(0, (idx.count or 1) - 1)
    idx.nameVersion = (idx.nameVersion or 0) + 1
    local list = e.id and idx.byId[e.id]
    if list then
        for i = #list, 1, -1 do if list[i] == e then table.remove(list, i) end end
    end
    idx.version = idx.version + 1
end

function Ledger:NameArrived(itemID)
    for _, idx in pairs(self.index) do
        local list = idx.byId[itemID]
        if list then
            for _, e in ipairs(list) do self:FillNames(e) end
            idx.version = idx.version + 1
            idx.nameVersion = (idx.nameVersion or 0) + 1
        end
    end
    ML:RequestUIRefresh(nil, true)
end

-- Every record of one item (decoded once and kept while it doesn't change)
function Ledger:History(realmKey, key)
    local realm = realmKey and self:Realm(realmKey)
    local s = realm and realm.items[key]
    if not s then return nil end
    local h = self.hist
    if h and h.realm == realmKey and h.key == key and h.s == s then return h.list, h.bad end
    local list, bad = Codec.Decode(s)
    self.hist = { realm = realmKey, key = key, s = s, list = list, bad = bad }
    return list, bad
end

-------------------------------------------------------------------------------
-- Scan detail
-------------------------------------------------------------------------------
function Ledger:Scans(realmKey, create)
    local realm = realmKey and self:Realm(realmKey, create)
    if not realm then return nil end
    local sc = realm.scans
    if not sc and create then
        sc = { seq = 0, log = {}, count = {}, full = {}, items = {}, lastFull = 0 }
        realm.scans = sc
    end
    return sc
end

local hookedDB, lastInfo
function Ledger:HookScans()
    local Au = A()
    local db = type(Au) == "table" and Au.Database
    if type(db) ~= "table" or type(db.ProcessScan) ~= "function" then
        self.scanHook = false
        return false
    end
    if hookedDB ~= db then        -- Auctionator rebuilds its Database after some of its own commands
        hooksecurefunc(db, "ProcessScan", function(_, info) Ledger:OnScan(info) end)   -- RETEST: Auctionator internal
        hookedDB = db
    end
    self.scanHook = true
    return true
end

Ledger.scanQueue = {}

function Ledger:OnScan(info)
    if type(info) ~= "table" or info == lastInfo then return end
    lastInfo = info
    if not ML.db or not ML.db.settings.recordScans then return end
    local key = self:CurrentRealmKey()
    if not key then self:RealmUnknownNotice() return end
    self.scanQueue[#self.scanQueue + 1] = { info = info, t = time(), key = key }
    if not self.scanJob then self:NextScan() end
    self:ScheduleRecord(20, "scan", true)     -- keeps the daily ledger current while the AH stays open
end

-- A scan counts as full when it lists most of what the last full scan did;
-- only full scans say anything about items that were NOT on sale.
local FULL_MIN, FULL_SHARE = 500, 0.5

function Ledger:NextScan()
    if self.scanMerging then return end               -- picked up again when the move finishes
    local req = table.remove(self.scanQueue, 1)
    if not req then return end
    local sc = self:Scans(req.key, true)
    local info = req.info
    local keys = {}
    for k, v in pairs(info) do
        if type(k) == "string" and type(v) == "table" then keys[#keys + 1] = k end
    end
    local id = sc.seq + 1
    sc.seq = id
    sc.log[id], sc.count[id] = req.t, #keys
    if #keys >= math.max(FULL_MIN, floor((sc.lastFull or 0) * FULL_SHARE)) then
        sc.full[id], sc.lastFull = true, #keys
    end
    local items = sc.items
    local daily = self:Realm(req.key, true).items       -- each scan also adds to this auction house's daily prices
    local today = math.floor((req.t - ns.ScanDay0()) / 86400)
    local job = { name = "scan", label = "saving scan detail", key = req.key, keys = keys, i = 1, saved = 0, id = id, dailyAdded = 0 }
    function job:Step(deadline)
        local compress = ML.db.settings.compress
        local list, n = self.keys, #self.keys
        while self.i <= n do
            local k = list[self.i]
            self.i = self.i + 1
            local entries, low, total = info[k], nil, 0
            for j = 1, #entries do
                local e = entries[j]
                local p = type(e) == "table" and Num(e.price)
                if p and p > 0 then
                    if not low or p < low then low = p end
                    local a = Num(e.available)
                    if a and a > 0 then total = total + a end
                end
            end
            if low then
                local P = Codec.NewList()
                Codec.Push(P, id, floor(low), floor(low), floor(total))
                local new = Codec.Merge(items[k], P, floor(low), compress, nil)
                if new then items[k] = new; self.saved = self.saved + 1 end
                -- same rule as Auctionator's daily prices: lowest and highest of the
                -- scans' lowest buyouts that day, and the most units on sale
                local D = Codec.NewList()
                Codec.Push(D, today, floor(low), floor(low), floor(total))
                local old = daily[k]
                local newDaily, added = Codec.Merge(old, D, floor(low), compress, today)
                if newDaily and newDaily ~= old then
                    daily[k] = newDaily
                    self.dailyAdded = self.dailyAdded + added
                    Ledger:IndexPut(self.key, k, newDaily)
                end
            end
            if ns.Clock() >= deadline then return false end
        end
        return true
    end
    function job:Progress() return self.i - 1, #self.keys end
    function job:OnDone() Ledger:ScanDone(self) end
    self.scanJob = job
    ns.StartJob(job)
end

function Ledger:ScanDone(job)
    self.scanJob = nil
    local sc = self:Scans(job.key)
    if sc and not job.failed then
        sc.lastScan = sc.log[job.id]
        self.scanStatus = ("Last scan: %s item%s %s (%s)."):format(ns.Commas(job.saved), job.saved == 1 and "" or "s",
            sc.full[job.id] and "in a full scan" or "in a partial scan", ns.TimeLabel(sc.lastScan))
    end
    if self.scanHist and self.scanHist.realm == job.key then self.scanHist = nil end
    if self.hist and self.hist.realm == job.key then self.hist = nil end
    local realm = self:Realm(job.key)
    if realm and not job.failed and job.saved > 0 then realm.lastRecord = time() end
    self:PruneScans(job.key)
    self:StatsChanged(job.key, true)
    self:NextScan()
    ML:RequestUIRefresh(nil, true)
end

-- Scan detail older than keepScanDays goes, a sealed block (128 scans of an item) at a time
function Ledger:PruneScans(realmKey, force)
    local sc = self:Scans(realmKey)
    if not sc then return end
    local today, keep = ns.Today(), ML.db.settings.keepScanDays
    if not force and sc.prunedOn == today and sc.prunedKeep == keep then return end
    sc.prunedOn, sc.prunedKeep = today, keep
    local cutoffT, cutoffId = time() - keep * 86400, nil
    for id, t in pairs(sc.log) do
        if t < cutoffT then
            sc.log[id], sc.count[id], sc.full[id] = nil, nil, nil
        elseif not cutoffId or id < cutoffId then
            cutoffId = id
        end
    end
    cutoffId = cutoffId or (sc.seq + 1)
    ItemJob("pruneScans", "removing old scan detail", realmKey, function(_, k, s, items)
        local new, n = Codec.Prune(s, cutoffId)
        if n > 0 then items[k] = new end
    end, function()
        Ledger.scanHist = nil
        Ledger:RefreshScanStats(realmKey)
    end, "scans")
end

function Ledger:RefreshScanStats(realmKey)
    local realm, sc = self:Realm(realmKey), self:Scans(realmKey)
    if not realm or not sc then return end
    local st = { items = 0, records = 0, bytes = 0, unpacked = 0, compressed = 0, scans = 0, full = 0 }
    for id, t in pairs(sc.log) do
        st.scans = st.scans + 1
        if sc.full[id] then st.full = st.full + 1 end
        if not st.first or t < st.first then st.first = t end
        if not st.last or t > st.last then st.last = t end
    end
    ItemJob("scanStats", "measuring scan detail", realmKey, function(_, _, s)
        local m, _, count, _, _, _, comp, _, unpacked = Codec.Summary(s)
        if not m then return end
        st.items = st.items + 1
        st.records = st.records + count
        st.bytes = st.bytes + #s
        st.unpacked = st.unpacked + unpacked
        st.compressed = st.compressed + comp
    end, function()
        realm.scanStats = st
        ML:RequestUIRefresh(nil, true)
    end, "scans")
end

-- One item's scan records with times: { n, t = {}, lo = {}, q = {}, id = {}, bad }
function Ledger:ScanHistory(realmKey, key)
    local sc = self:Scans(realmKey)
    local s = sc and sc.items[key]
    if not s then return nil end
    local h = self.scanHist
    if h and h.realm == realmKey and h.key == key and h.s == s then return h.series end
    local L, bad = Codec.Decode(s)
    local series = { n = 0, t = {}, lo = {}, q = {}, id = {}, bad = bad }
    for i = 1, L.n do
        local t = sc.log[L.d[i]]
        if t then                          -- records older than the kept scan log have no time
            local n = series.n + 1
            series.n = n
            series.t[n], series.lo[n], series.q[n], series.id[n] = t, L.l[i], L.q[i], L.d[i]
        end
    end
    self.scanHist = { realm = realmKey, key = key, s = s, series = series }
    return series
end

-- Times of full scans in [fromT, toT] that did not list the item (sorted),
-- plus how many full scans there were in that window
function Ledger:MissedScans(realmKey, series, fromT, toT)
    local sc = self:Scans(realmKey)
    local out, fulls = {}, 0
    if not sc then return out, 0 end
    local seen = {}
    for i = 1, series.n do seen[series.id[i]] = true end
    for id in pairs(sc.full) do
        local t = sc.log[id]
        if t and t >= fromT and t <= toT then
            fulls = fulls + 1
            if not seen[id] then out[#out + 1] = t end
        end
    end
    table.sort(out)
    return out, fulls
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
function Ledger:OnLogin()
    for key, realm in pairs(ML.db.realms) do
        if not realm.stats then self:RefreshStats(key) end
        if realm.scans and not realm.scanStats then self:RefreshScanStats(key) end
        self.statsAt[key] = time()                    -- next routine measurement in 10 minutes
    end
    self:HookScans()
    self:ScheduleRecord(10, "login", true)
    -- 0.2.9, once: read every Auctionator price list in full again. Merging is
    -- idempotent; this picks up days a session past midnight left unread.
    if (ML.db.catchUp or 0) < 1 then
        C_Timer.After(20, function()
            if (ML.db.catchUp or 0) < 1 then
                ML.db.catchUp = 1
                Ledger:ImportAll(true)
            end
        end)
    end
end

-- Auctionator can rebuild its Database; make sure the scan hook is on the current one
ns.On("AUCTION_HOUSE_SHOW", function()
    Ledger:HookScans()
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
    Ledger:ScheduleRecord(4, "auction house closed", true)
end)

-- a full scan's data arrived; give Auctionator time to process it
ns.On("REPLICATE_ITEM_LIST_UPDATE", function()                  -- RETEST
    Ledger:ScheduleRecord(30, "full scan", true)
end)

ns.On("ITEM_DATA_LOAD_RESULT", OnItemLoaded)                    -- RETEST
ns.On("GET_ITEM_INFO_RECEIVED", OnItemLoaded)
