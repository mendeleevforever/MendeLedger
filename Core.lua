local addonName, ns = ...
-- Core.lua
-- MendeLedger keeps a long-term ledger of the daily prices Auctionator scans.
-- Auctionator forgets prices after its history window (21 days by default);
-- MendeLedger copies each day into MendeLedgerDB, packed small (Codec.lua),
-- so the history keeps growing and can be searched and graphed (UI.lua).
--
-- This file: shared helpers, SavedVariables (created in ADDON_LOADED and
-- merged onto defaults), the one event frame with its handler table, the
-- out-of-combat queue, the background job runner, the capability probe and
-- the /mendel command.
--
-- MendeLedger reads no unit data at all (no UnitHealth, UnitName, UnitExists
-- or similar) and never touches the combat log or secure snippets. Values that
-- come from game APIs (item names, realm names, links, build info) still go
-- through ns.Text / ns.Num, which drop Midnight "secret" values before
-- anything compares, prints or does arithmetic with them.
--
-- Lines marked RETEST depend on the client build; check them when the
-- interface number moves off 16001.

local ML = {}
ns.ML = ML
_G.MendeLedger = ML

ML.VERSION          = "0.2.3"
ML.TESTED_INTERFACE = 16001                                   -- RETEST: the build this was written against
ML.PREFIX           = "|cffe6b422MendeLedger:|r "

local floor = math.floor

-------------------------------------------------------------------------------
-- Secret-value guards
-------------------------------------------------------------------------------
local issecretvalue = issecretvalue                           -- RETEST: Midnight secret values

function ns.IsSecret(v)
    if v == nil or issecretvalue == nil then return false end
    return issecretvalue(v) and true or false
end

-- A usable string from a game API, or nil (secret, empty or not a string)
function ns.Text(v)
    if type(v) ~= "string" or ns.IsSecret(v) or v == "" then return nil end
    return v
end

-- A usable number, or nil (secret, NaN or not a number)
function ns.Num(v)
    if type(v) ~= "number" or ns.IsSecret(v) then return nil end
    if v ~= v then return nil end
    return v
end

function ns.Print(msg)
    print(ML.PREFIX .. tostring(msg))
end

function ns.Trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- pcall here only isolates Lua errors from optional APIs; it does not make a
-- protected call safe, and nothing in MendeLedger makes protected calls.
function ns.SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g = pcall(fn, ...)
    if ok then return a, b, c, d, e, f, g end
    return nil
end

-------------------------------------------------------------------------------
-- Numbers, money, sizes, dates
-------------------------------------------------------------------------------
function ns.Commas(n)
    n = ns.Num(n) or 0
    local s = ("%.0f"):format(n)
    local neg = s:sub(1, 1) == "-"
    if neg then s = s:sub(2) end
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return (neg and "-" or "") .. out
end

function ns.Bytes(n)
    n = ns.Num(n) or 0
    if n < 1024 then return ("%d bytes"):format(n) end
    if n < 1024 * 1024 then return ("%.0f KB"):format(n / 1024) end
    return ("%.1f MB"):format(n / (1024 * 1024))
end

local GOLD, SILVER, COPPER = "|cffffd700", "|cffc7c7cf", "|cffeda55f"

-- Money with coin icons, like the game's own price displays
function ns.Coins(copper)
    copper = ns.Num(copper)
    if not copper then return "|cff9d9d9d—|r" end
    copper = floor(copper + 0.5)
    if GetCoinTextureString then                              -- RETEST
        local s = ns.SafeCall(GetCoinTextureString, copper, 12)
        if type(s) == "string" then return s end
    end
    return ns.Money(copper)
end

-- Compact coloured text with the two biggest units: "12g 50s", "7s 25c", "40c"
function ns.Money(copper)
    copper = ns.Num(copper)
    if not copper then return "|cff9d9d9d—|r" end
    copper = floor(copper + 0.5)
    local g, s, c = floor(copper / 10000), floor((copper % 10000) / 100), copper % 100
    if g > 0 then
        if s > 0 and g < 1000 then return ("%s%s|rg %s%d|rs"):format(GOLD, ns.Commas(g), SILVER, s) end
        return ("%s%s|rg"):format(GOLD, ns.Commas(g))
    end
    if s > 0 then
        if c > 0 then return ("%s%d|rs %s%d|rc"):format(SILVER, s, COPPER, c) end
        return ("%s%d|rs"):format(SILVER, s)
    end
    return ("%s%d|rc"):format(COPPER, c)
end

-- Graph axis labels: "1.5g", "50s", "40c"
function ns.AxisMoney(copper)
    copper = ns.Num(copper) or 0
    if copper >= 10000 then
        local g = copper / 10000
        if g >= 100 or floor(g) == g then return ("%sg"):format(ns.Commas(floor(g + 0.5))) end
        return (("%.1f"):format(g):gsub("%.0$", "")) .. "g"
    end
    if copper >= 100 then
        local s = copper / 100
        if floor(s) == s then return ("%ds"):format(s) end
        return (("%.1f"):format(s):gsub("%.0$", "")) .. "s"
    end
    return ("%dc"):format(floor(copper + 0.5))
end

-- Auctionator counts days from 1 Jan 2020, local time. Use its own constant
-- when it is there so both ledgers agree on what "a day" is.
local day0
function ns.ScanDay0()
    if not day0 then
        local A = rawget(_G, "Auctionator")
        local c = type(A) == "table" and type(A.Constants) == "table" and ns.Num(A.Constants.SCAN_DAY_0)   -- RETEST
        day0 = c or time({ year = 2020, month = 1, day = 1, hour = 0 })
    end
    return day0
end

function ns.Today()
    return floor((time() - ns.ScanDay0()) / 86400)
end

-- noon of that day, so daylight saving never shifts the date
function ns.DayTime(day)
    return ns.ScanDay0() + day * 86400 + 43200
end

function ns.DayLabel(day)                 -- "Nov 4"
    if not day then return "?" end
    local t = ns.DayTime(day)
    return ("%s %d"):format(date("%b", t), tonumber(date("%d", t)))
end

function ns.DayDate(day)                  -- "Nov 4, 2026"
    if not day then return "unknown date" end
    local t = ns.DayTime(day)
    return ("%s %d, %s"):format(date("%b", t), tonumber(date("%d", t)), date("%Y", t))
end

-- Time of day, following the game clock's 12/24-hour setting
local function Use24Hour()
    local get = (C_CVar and C_CVar.GetCVarBool) or rawget(_G, "GetCVarBool")   -- RETEST
    local v = get and ns.SafeCall(get, "timeMgrUseMilitaryTime")
    if v == nil then return true end
    return v and true or false
end

function ns.TimeLabel(t)                  -- "14:30" or "2:30 PM"
    t = ns.Num(t)
    if not t then return "?" end
    if Use24Hour() then return date("%H:%M", t) end
    local h = tonumber(date("%H", t))
    local suffix = h >= 12 and "PM" or "AM"
    h = h % 12
    if h == 0 then h = 12 end
    return ("%d:%s %s"):format(h, date("%M", t), suffix)
end

function ns.WhenLabel(t)                  -- "Mon 2:30 PM"
    t = ns.Num(t)
    if not t then return "?" end
    return ("%s %s"):format(date("%a", t), ns.TimeLabel(t))
end

function ns.Ago(t)
    t = ns.Num(t)
    if not t or t <= 0 then return "never" end
    local d = time() - t
    if d < 60 then return "just now" end
    if d < 3600 then local m = floor(d / 60); return m == 1 and "1 minute ago" or (m .. " minutes ago") end
    if d < 86400 then local h = floor(d / 3600); return h == 1 and "1 hour ago" or (h .. " hours ago") end
    local days = floor(d / 86400)
    return days == 1 and "yesterday" or (days .. " days ago")
end

-------------------------------------------------------------------------------
-- SavedVariables: created in ADDON_LOADED (never at file scope), merged onto defaults
-------------------------------------------------------------------------------
ns.DEFAULTS = {
    schema   = 1,
    settings = {
        autoRecord  = true,       -- record after auction house scans
        compress    = true,       -- compress sealed blocks when useful
        keepDays    = 0,          -- 0 = keep everything
        announce    = true,       -- one chat line after a recording that added prices
        recordScans = true,       -- keep every Auctionator scan (prices by time of day)
        keepScanDays = 14,        -- how long scan detail is kept (7, 14 or 30)
        useScans    = true,       -- ranges up to 7 days show every scan when there is scan detail
        range       = 30,         -- graph range in days, 0 = all
        showQty     = true,
        showBand    = true,
        sort        = "name",     -- name | price | change | days
        groupByType = true,
        searchTooltips = true,    -- search item tooltips (stats, effects, set bonuses), not just names
        recentOnly  = false,
        multiDay    = false,
        lastTab     = "ledger",
    },
    collapsed   = {},             -- [item type name] = true
    minimap     = { hide = false },
    positions   = {},
    names       = {},             -- [itemID or "p:species"] = quality digit .. name
    namesLocale = "",
    realms      = {},             -- [Auctionator realm key] = { items = { [key] = packed }, ... }
}

local function Copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = Copy(x) end
    return t
end
ns.Copy = Copy

-- Fills in anything missing (or of the wrong type) from the defaults,
-- keeps everything the player already has.
local function MergeDefaults(dst, defaults)
    for k, v in pairs(defaults) do
        if dst[k] == nil or type(dst[k]) ~= type(v) then
            dst[k] = Copy(v)
        elseif type(v) == "table" then
            MergeDefaults(dst[k], v)
        end
    end
    return dst
end

function ML:InitDB()
    if type(MendeLedgerDB) ~= "table" then MendeLedgerDB = {} end
    local db = MergeDefaults(MendeLedgerDB, ns.DEFAULTS)

    for key, r in pairs(db.realms) do
        if type(key) ~= "string" or type(r) ~= "table" then
            db.realms[key] = nil
        else
            if type(r.items) ~= "table" then r.items = {} end
            for k, s in pairs(r.items) do
                if type(k) ~= "string" or type(s) ~= "string" then r.items[k] = nil end
            end
            r.settled = ns.Num(r.settled)
            local sc = r.scans
            if sc ~= nil and type(sc) ~= "table" then
                r.scans = nil
            elseif sc then
                for _, field in ipairs({ "log", "count", "full", "items" }) do
                    if type(sc[field]) ~= "table" then sc[field] = {} end
                end
                for k, v in pairs(sc.items) do
                    if type(k) ~= "string" or type(v) ~= "string" then sc.items[k] = nil end
                end
                sc.seq = ns.Num(sc.seq) or 0
                for id in pairs(sc.log) do
                    if type(id) == "number" and id > sc.seq then sc.seq = id end
                end
                sc.lastFull = ns.Num(sc.lastFull) or 0
            end
        end
    end
    for k, v in pairs(db.names) do
        if type(v) ~= "string" then db.names[k] = nil end
    end
    -- item names are cached in the client's language; start over if it changed
    local locale = GetLocale and ns.Text(GetLocale()) or ""
    if db.namesLocale ~= locale then
        wipe(db.names)
        db.namesLocale = locale
    end
    self.db = db
end

-------------------------------------------------------------------------------
-- One event frame, one handler table keyed by event name
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
local handlers = {}
ns.eventOK = {}

-- Registers (or replaces) the handler for an event. Unknown events are
-- reported by the probe instead of breaking the load.
function ns.On(event, fn)
    handlers[event] = fn
    local ok = pcall(events.RegisterEvent, events, event)
    ns.eventOK[event] = ok
    return ok
end

events:SetScript("OnEvent", function(_, event, ...)
    local h = handlers[event]
    if h and (event == "ADDON_LOADED" or ML.db) then h(...) end
end)

-------------------------------------------------------------------------------
-- Out-of-combat queue: anything touching a protected frame (the Blizzard
-- Settings panel is the only one MendeLedger touches) waits for combat to end
-------------------------------------------------------------------------------
local combatQueue, combatOrder = {}, {}

function ns.AfterCombat(key, fn)
    if not InCombatLockdown() then
        fn()
        return true
    end
    if not combatQueue[key] then combatOrder[#combatOrder + 1] = key end
    combatQueue[key] = fn
    return false
end

local function FlushCombatQueue()
    local order = combatOrder
    combatOrder = {}
    for _, key in ipairs(order) do
        local fn = combatQueue[key]
        combatQueue[key] = nil
        if fn then
            local ok, err = pcall(fn)
            if not ok then ns.Print("|cffff4040error:|r " .. tostring(err)) end
        end
    end
end

-------------------------------------------------------------------------------
-- Background jobs: recording, indexing, repacking and pruning run a few
-- milliseconds per frame (C_Timer, not OnUpdate) and pause during combat.
-- A job is { name = "...", Step = function(job, deadline) return done end,
--            OnDone = function(job) end, Progress = function(job) return done, total end }
-------------------------------------------------------------------------------
local jobs, pumping = {}, false
local BUDGET_MS = 5
local clock = debugprofilestop                                -- RETEST
    or function() return (GetTimePreciseSec and GetTimePreciseSec() or GetTime()) * 1000 end
ns.Clock = clock

local Pump
local function Schedule()
    if pumping then return end
    pumping = true
    C_Timer.After(0, Pump)
end

Pump = function()
    pumping = false
    if #jobs == 0 then return end
    if InCombatLockdown() then
        ns.AfterCombat("jobs", Schedule)
        return
    end
    local deadline = clock() + BUDGET_MS
    repeat
        local job = jobs[1]
        local ok, done = pcall(job.Step, job, deadline)
        if not ok then
            ns.Print(("|cffff4040error|r while %s: %s"):format(job.label or job.name, tostring(done)))
            job.failed, done = true, true
        end
        if done then
            table.remove(jobs, 1)
            if job.OnDone then
                local ok2, err = pcall(job.OnDone, job)
                if not ok2 then ns.Print("|cffff4040error:|r " .. tostring(err)) end
            end
        end
    until #jobs == 0 or clock() >= deadline
    if ML.OnJobProgress then ML:OnJobProgress() end
    if #jobs > 0 then Schedule() end
end

function ns.StartJob(job)
    jobs[#jobs + 1] = job
    Schedule()
    return job
end

function ns.FindJob(name)
    for _, job in ipairs(jobs) do
        if job.name == name then return job end
    end
    return nil
end

function ns.CurrentJob()
    return jobs[1]
end

-------------------------------------------------------------------------------
-- Capability probe (/mendel probe and the Options tab). Nothing here picks a
-- code path from the project ID; each feature checks the API it needs.
-------------------------------------------------------------------------------
function ns.Probe()
    local out = {}
    local function Add(label, ok, detail) out[#out + 1] = { label = label, ok = ok and true or false, detail = detail } end

    local build, _, _, iface = GetBuildInfo()                  -- RETEST
    iface, build = ns.Num(iface), ns.Text(build)
    Add("Interface", iface == ML.TESTED_INTERFACE,
        ("%s (build %s; written for %d)"):format(tostring(iface or "?"), build or "?", ML.TESTED_INTERFACE))

    local proj = ns.Num(rawget(_G, "WOW_PROJECT_ID"))          -- RETEST: informational only
    local projName = "unknown"
    if proj then
        if proj == rawget(_G, "WOW_PROJECT_CAMELOT") then projName = "Forever (Camelot)"
        elseif proj == rawget(_G, "WOW_PROJECT_MAINLINE") then projName = "Mainline"
        elseif proj == rawget(_G, "WOW_PROJECT_CLASSIC") then projName = "Classic" end
    end
    Add("Game type", true, ("%s = %s (shown only, never used to choose behaviour)"):format(tostring(proj or "?"), projName))

    local LC = LibStub and LibStub("LibCompress", true)
    Add("Deflate compression", LC and LC.HasZlibCodecs and LC:HasZlibCodecs(),
        "C_EncodingUtil through LibCompress r87")               -- RETEST
    Add("Graph lines", UIParent and UIParent.CreateLine ~= nil, "Frame:CreateLine")   -- RETEST
    Add("Item info", C_Item and C_Item.GetItemInfoInstant and C_Item.GetItemNameByID,
        "C_Item.GetItemInfoInstant, C_Item.GetItemNameByID")   -- RETEST
    Add("Item loading", C_Item and C_Item.RequestLoadItemDataByID and ns.eventOK.ITEM_DATA_LOAD_RESULT,
        "C_Item.RequestLoadItemDataByID + ITEM_DATA_LOAD_RESULT")   -- RETEST
    Add("Secret values", true, issecretvalue and "issecretvalue present: guards active" or "issecretvalue absent: guards idle")
    Add("Tooltip search", true, (C_TooltipInfo and C_TooltipInfo.GetItemByID) and "reads tooltips with C_TooltipInfo.GetItemByID"
        or "C_TooltipInfo missing: reads tooltips with a hidden tooltip")
    Add("Scan events", ns.eventOK.AUCTION_HOUSE_CLOSED,
        ns.eventOK.REPLICATE_ITEM_LIST_UPDATE and "AUCTION_HOUSE_CLOSED, REPLICATE_ITEM_LIST_UPDATE" or "AUCTION_HOUSE_CLOSED only")
    if ns.Ledger and ns.Ledger.SourceProbe then ns.Ledger:SourceProbe(Add) end
    return out
end

function ML:PrintProbe()
    ns.Print("client check:")
    for _, r in ipairs(ns.Probe()) do
        print(("  %s  %s  |cff9c8d70%s|r"):format(r.ok and "|cff40ff40OK|r" or "|cffff6040--|r", r.label, r.detail or ""))
    end
end

-------------------------------------------------------------------------------
-- /mendel
-------------------------------------------------------------------------------
local HELP = {
    { "/mendel", "open / close the window" },
    { "/mendel <text>", "open the window and search (names, types, stats, effects, set bonuses or an item ID)" },
    { "/mendel record", "record Auctionator's prices now" },
    { "/mendel import", "record every realm Auctionator has prices for" },
    { "/mendel realms", "list the realms in the ledger" },
    { "/mendel realm <name>", "show another realm's history" },
    { "/mendel keep <days | forever>", "how long to keep history (e.g. /mendel keep 365)" },
    { "/mendel compress on | off", "compress sealed history (when it saves 10% or more)" },
    { "/mendel scans on | off", "keep every Auctionator scan, for prices by time of day" },
    { "/mendel keepscans <7 | 14 | 30>", "how many days of scan detail to keep" },
    { "/mendel repack", "re-store sealed history to match the compression setting" },
    { "/mendel stats", "storage used by the ledger" },
    { "/mendel minimap", "show / hide the minimap button" },
    { "/mendel options", "open the Options tab" },
    { "/mendel reset", "move the window back to the middle of the screen" },
    { "/mendel probe", "check which game features this client provides" },
    { "/mendel forget", "forget the history of the realm being shown (asks first)" },
}

function ML:PrintHelp()
    ns.Print("commands:")
    for _, line in ipairs(HELP) do
        print(("  |cffffd100%s|r  %s"):format(line[1], line[2]))
    end
end

local commands = {}
commands[""] = function() ML:Toggle() end
commands.help = function() ML:PrintHelp() end
commands["?"] = commands.help
commands.record = function() ns.Ledger:RecordNow("command", false) end
commands.now = commands.record
commands.scan = commands.record
commands.import = function() ns.Ledger:ImportAll() end
commands.repack = function() ns.Ledger:Repack(false) end
commands.stats = function() ns.Ledger:PrintStats() end
commands.probe = function() ML:PrintProbe() end
commands.options = function() ML:Open("options") end
commands.config = commands.options
commands.forget = function() ML:ConfirmForget(ns.Ledger:ShownRealm()) end
commands.reset = function()
    ML.db.positions.main = nil
    if ML.frame then ML:PlaceMainFrame() end
    ns.Print("window moved back to the middle of the screen.")
end
commands.minimap = function()
    local show = ML.db.minimap.hide and true or false
    ML:SetMinimapButtonShown(show)
    ns.Print("minimap button " .. (show and "shown." or "hidden. Type /mendel minimap to show it again."))
end
commands.compress = function(rest)
    rest = rest:lower()
    if rest ~= "on" and rest ~= "off" then
        ns.Print("compression is " .. (ML.db.settings.compress and "on" or "off") .. ". Use /mendel compress on or off.")
        return
    end
    ML:SetCompress(rest == "on")
end
commands.scans = function(rest)
    rest = rest:lower()
    if rest ~= "on" and rest ~= "off" then
        ns.Print("scan detail is " .. (ML.db.settings.recordScans and "on" or "off") .. ". Use /mendel scans on or off.")
        return
    end
    ML:SetRecordScans(rest == "on")
end
commands.keepscans = function(rest)
    local days = tonumber(rest)
    if days ~= 7 and days ~= 14 and days ~= 30 then
        ns.Print("use /mendel keepscans 7, 14 or 30.")
        return
    end
    ML:SetKeepScanDays(days)
end
commands.keep = function(rest)
    rest = rest:lower()
    local days = (rest == "forever" or rest == "all" or rest == "0") and 0 or tonumber(rest)
    if not days or days < 0 or (days > 0 and days < 30) then
        ns.Print("use /mendel keep forever, or a number of days (30 or more).")
        return
    end
    ML:SetKeepDays(floor(days))
end
commands.realms = function()
    local list = ns.Ledger:RealmList()
    if #list == 0 then ns.Print("the ledger is empty. Scan the auction house with Auctionator first.") return end
    ns.Print("realms in the ledger:")
    for _, r in ipairs(list) do
        print(("  |cffffd100%s|r  %s items, last recorded %s"):format(r.name, ns.Commas(r.items), ns.Ago(r.lastRecord)))
    end
end
commands.realm = function(rest)
    local key = ns.Ledger:FindRealm(rest)
    if not key then ns.Print("no realm in the ledger matches \"" .. rest .. "\". Try /mendel realms.") return end
    ML:ShowRealm(key)
    ML:Open("ledger")
end

SLASH_MENDELEDGER1 = "/mendel"
SLASH_MENDELEDGER2 = "/mendeledger"
SlashCmdList["MENDELEDGER"] = function(msg)
    if not ML.db then return end
    msg = ns.Trim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    local fn = commands[(cmd or ""):lower()]
    if fn then
        fn(ns.Trim(rest or ""))
    else
        ML:OpenSearch(msg)
    end
end

-------------------------------------------------------------------------------
-- Load
-------------------------------------------------------------------------------
ns.On("ADDON_LOADED", function(name)
    if name ~= addonName then return end
    ML:InitDB()
    events:UnregisterEvent("ADDON_LOADED")
end)

-- Each startup step is isolated, so a problem in one (say the minimap button
-- on a new build) can never stop recording.
local function Step(what, fn)
    local ok, err = pcall(fn)
    if not ok then ns.Print(("|cffff4040%s failed:|r %s"):format(what, tostring(err))) end
end

ns.On("PLAYER_LOGIN", function()
    if ns.Ledger then Step("recording setup", function() ns.Ledger:OnLogin() end) end
    if ML.InitUI then ML:InitUI(Step) end
    print(("|cffe6b422MendeLedger %s|r loaded  —  /mendel to browse Auctionator price history"):format(ML.VERSION))
    local iface = ns.Num((select(4, GetBuildInfo())))           -- RETEST
    if iface and iface ~= ML.TESTED_INTERFACE then
        ns.Print(("this client reports interface %d; MendeLedger was written for %d. Type /mendel probe to check what still works."):format(iface, ML.TESTED_INTERFACE))
    end
end)

ns.On("PLAYER_REGEN_ENABLED", FlushCombatQueue)
