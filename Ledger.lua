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

-- The key Auctionator files the current realm under (its connected-realm
-- root), so both ledgers line up and imports map one to one.
function Ledger:CurrentRealmKey()
    local Au = A()
    if type(Au) == "table" then
        if type(Au.State) == "table" and Text(Au.State.CurrentRealm) then return Au.State.CurrentRealm end   -- RETEST
        if type(Au.Variables) == "table" then
            local r = Text((ns.SafeCall(Au.Variables.GetConnectedRealmRoot)))
            if r then return r end
        end
    end
    local list = GetAutoCompleteRealms and ns.SafeCall(GetAutoCompleteRealms)   -- RETEST
    if type(list) == "table" and #list > 0 then
        local copy = {}
        for _, name in ipairs(list) do
            if Text(name) then copy[#copy + 1] = name end
        end
        table.sort(copy)
        if copy[1] then return copy[1] end
    end
    return Text(GetNormalizedRealmName and ns.SafeCall(GetNormalizedRealmName))
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
    if not key then return nil, nil, "The realm isn't known yet; try again in a moment." end
    local v = root[key]
    if type(v) == "table" then return v, key end
    if type(v) == "string" then
        local t = self:DecodeCBOR(v)
        if t then return t, key end
        return nil, key, "Auctionator's prices for this realm couldn't be unpacked."
    end
    return nil, key, "Auctionator has no prices for this realm yet. Scan the auction house first."
end

function Ledger:SourceProbe(Add)
    local present = self:AuctionatorPresent()
    Add("Auctionator", present, present and ("version " .. (self:AuctionatorVersion() or "?")) or "not loaded (the ledger still opens)")
    local root = rawget(_G, "AUCTIONATOR_PRICE_DATABASE")
    if type(root) == "table" then
        local v = Num(root.__dbversion)
        Add("Price database format", v == 8, ("version %s (written for 8)"):format(tostring(v or "?")))   -- RETEST
    end
    local src, key, err = self:LiveSource()
    Add("Realm prices", src ~= nil, src and ("realm key " .. tostring(key)) or err)
    Add("Day numbering", true, ("today is day %d (%s)"):format(ns.Today(), ns.DayDate(ns.Today())))
end

-------------------------------------------------------------------------------
-- Realms in the ledger
-------------------------------------------------------------------------------
function Ledger:Realm(key, create)
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
    return (r and Text(r.name)) or key or "?"
end

function Ledger:RealmList()
    local out = {}
    for key, r in pairs(ML.db.realms) do
        local st = r.stats or {}
        out[#out + 1] = { key = key, name = self:RealmName(key), items = st.items or 0, lastRecord = r.lastRecord,
                          first = st.first, last = st.last }
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
    self.hist = nil
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
    if not src then
        self.status = err
        if not silent then ns.Print(err) end
        ML:RequestUIRefresh()
        return false
    end
    self:Enqueue({ key = key, src = src, reason = reason, silent = silent, current = true })
    return true
end

-- /mendel import: every realm Auctionator knows, all days (merging is idempotent)
function Ledger:ImportAll()
    local root = rawget(_G, "AUCTIONATOR_PRICE_DATABASE")
    if type(root) ~= "table" then ns.Print("Auctionator isn't loaded, so there is nothing to import.") return end
    local liveSrc, liveKey = self:LiveSource()
    local n, failed = 0, 0
    for key, v in pairs(root) do
        if type(key) == "string" and key ~= "__dbversion" then
            local src
            if key == liveKey and liveSrc then src = liveSrc
            elseif type(v) == "table" then src = v
            else src = self:DecodeCBOR(v) end
            if src then
                n = n + 1
                self:Enqueue({ key = key, src = src, reason = "import", full = true, silent = false, current = key == liveKey })
            else
                failed = failed + 1
            end
        end
    end
    if n == 0 and failed == 0 then ns.Print("Auctionator has no prices saved yet.") return end
    ns.Print(("importing %d realm%s from Auctionator%s."):format(n, n == 1 and "" or "s",
        failed > 0 and (" (%d couldn't be unpacked on this client)"):format(failed) or ""))
end

function Ledger:Enqueue(req)
    for _, q in ipairs(self.queue) do
        if q.key == req.key then
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
    if req.current then
        local name = Text(GetRealmName and ns.SafeCall(GetRealmName))
        if name then realm.name = name end
    end
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
            if self.i % 16 == 0 and ns.Clock() >= deadline then return false end
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
        realm.settled = job.today - 1
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
    self:RefreshStats(job.key)
    if job.again then self:RecordNow(job.req.reason, true) end
    self:NextHarvest()
    ML:RequestUIRefresh()
end

-------------------------------------------------------------------------------
-- Jobs over every item of a realm: stats, pruning, repacking, indexing
-------------------------------------------------------------------------------
local function ItemJob(name, label, realmKey, perItem, onDone)
    local realm = Ledger:Realm(realmKey)
    if not realm then return nil end
    local keys = {}
    for k in pairs(realm.items) do keys[#keys + 1] = k end
    local job = { name = name, label = label, key = realmKey, keys = keys, i = 1 }
    function job:Step(deadline)
        local items, list, n = realm.items, self.keys, #self.keys
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
        ML:RequestUIRefresh()
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
    for i, key in ipairs(keys) do
        ItemJob("repack", "repacking " .. self:RealmName(key), key, function(_, k, s, items)
            local new, did = Codec.Repack(s, compress)
            if did then items[k] = new; changed = changed + 1 end
        end, function()
            Ledger:RefreshStats(key)
            if i == #keys and not quiet then
                ns.Print(("repacked %s items (%s)."):format(ns.Commas(changed), compress and "compressed where it saves 10% or more" or "uncompressed"))
            end
        end)
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
end

-------------------------------------------------------------------------------
-- Item names: cached in MendeLedgerDB, loaded from the server a few at a time
-------------------------------------------------------------------------------
local urgent, normal = { head = 1, tail = 0 }, { head = 1, tail = 0 }
local queued, queuedUrgent, pending, failed = {}, {}, {}, {}
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
        if not pending[id] and not failed[id] and not Ledger:CachedName(id) then
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

function Ledger:QueueName(id, isUrgent)
    if type(id) ~= "number" or failed[id] or pending[id] then return end
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
    if success == false then failed[itemID] = true return end
    if Ledger:ItemName(itemID) then
        Ledger:NameArrived(itemID)
    end
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
    if gid then return tonumber(gid), lvl, "gear" end
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
    e.label = label
    e.lname = label and label:lower() or nil
end

function Ledger:MakeEntry(key, s, e)
    local m, ref7, count, first, last = Codec.Summary(s)
    if not m then return nil end
    if not e then
        e = { key = key }
        e.id, e.ilvl, e.kind = ParseKey(key)
        if e.kind == "pet" then
            e.typeName, e.cls = "Battle Pets", 17
            if C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
                local _, icon = ns.SafeCall(C_PetJournal.GetPetInfoBySpeciesID, e.id)
                e.icon = icon
            end
        elseif e.id then
            local getInstant = (C_Item and C_Item.GetItemInfoInstant) or rawget(_G, "GetItemInfoInstant")   -- RETEST
            local _, itemType, itemSubType, _, icon, classID = ns.SafeCall(getInstant, e.id)
            e.typeName, e.subName, e.icon, e.cls = Text(itemType), Text(itemSubType), icon, Num(classID)
        end
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
    idx = { byKey = {}, byId = {}, ready = false, version = 0 }
    self.index[realmKey] = idx
    local realm = self:Realm(realmKey)
    if not realm then idx.ready = true return idx end
    local job = ItemJob("index", "indexing " .. self:RealmName(realmKey), realmKey, function(_, k, s)
        if not idx.byKey[k] then Ledger:IndexPut(realmKey, k, s) end
    end, function()
        idx.ready = true
        ML:RequestUIRefresh()
    end)
    if not job then idx.ready = true end
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
        end
    end
    ML:RequestUIRefresh(0.5)
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
-- Events
-------------------------------------------------------------------------------
function Ledger:OnLogin()
    for key, realm in pairs(ML.db.realms) do
        if not realm.stats then self:RefreshStats(key) end
    end
    self:ScheduleRecord(10, "login", true)
end

ns.On("AUCTION_HOUSE_CLOSED", function()
    Ledger:ScheduleRecord(4, "auction house closed", true)
end)

-- a full scan's data arrived; give Auctionator time to process it
ns.On("REPLICATE_ITEM_LIST_UPDATE", function()                  -- RETEST
    Ledger:ScheduleRecord(30, "full scan", true)
end)

ns.On("ITEM_DATA_LOAD_RESULT", OnItemLoaded)                    -- RETEST
ns.On("GET_ITEM_INFO_RECEIVED", OnItemLoaded)
