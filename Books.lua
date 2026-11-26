local addonName, ns = ...
-- Books.lua
-- The records behind the Ledger tab: auction house sales, purchases and
-- deposits, each with item, quantity, price and time, totalled by day, week,
-- month, quarter and year.
--
-- Where the records come from (all read only: MendeLedger never takes mail,
-- gold or items, and never buys or posts anything):
--   * Sales: "Auction successful" mail. While the mailbox is open, each mail is
--     checked with GetInboxInvoiceInfo; a seller invoice gives the item,
--     quantity, sale price, the auction house's cut and the deposit returned,
--     and the mail's gold is what was received.
--   * Purchases of items: "Auction won" mail (buyer invoices).
--   * Purchases of commodities: they go straight to the bags without mail, so
--     they're recorded when the purchase succeeds (StartCommoditiesPurchase,
--     COMMODITY_PRICE_UPDATED, ConfirmCommoditiesPurchase, then
--     COMMODITY_PURCHASE_SUCCEEDED). If an "Auction won" mail also arrives for
--     one, it's matched to the record instead of being counted again.
--   * Deposits: when an auction is posted (PostItem / PostCommodity, with
--     CalculateItemDeposit / CalculateCommodityDeposit), counted once the
--     auction exists (AUCTION_HOUSE_AUCTION_CREATED).
-- Mail has no ID, so a mail already counted is recognised by its invoice
-- details and its arrival time (worked out from daysLeft), matched one to one:
-- two identical sales are both counted, and no mail is counted twice.
--
-- Records live in MendeLedgerDB.books.tx: { t = time, k = "sale" | "buy" |
-- "deposit", h = auction house, ch = character (UnitGUID("player"), used whole
-- as a key, never parsed), id = itemID or nil, n = item name, q = quantity,
-- g = price (sale price, price paid, or deposit), c = AH cut, d = deposit
-- returned, m = gold received, src = "mail" or "ah" }.

local ML, Ledger = ns.ML, ns.Ledger
local Num, Text = ns.Num, ns.Text
local floor = math.floor

local Books = {}
ns.Books = Books

local MAIL_DAYS = 30            -- auction house mail stays 30 days
local MATCH_SECONDS = 600       -- the same mail's arrival works out within this on every check
local SEEN_DAYS = 40
local CREATED_WAIT = 60         -- seconds a post waits for AUCTION_HOUSE_AUCTION_CREATED

local function DB() return ML.db.books end

-------------------------------------------------------------------------------
-- Who and where
-------------------------------------------------------------------------------
-- The character key: UnitGUID("player") as a whole string (the guidelines'
-- choice for account-wide tables of characters; its stability across
-- sessions on Forever is not yet verified, so names are stored beside it)
function Books:Character()
    local guid = Text((ns.SafeCall(rawget(_G, "UnitGUID"), "player")))
    if not guid then return nil end
    local chars = ML.db.characters
    local c = chars[guid]
    if not c then c = {}; chars[guid] = c end
    local name = Text((ns.SafeCall(rawget(_G, "UnitName"), "player")))   -- names can be secret: then left unset
    if name then c.name = name end
    c.ah = Ledger:CurrentRealmKey() or c.ah
    c.seen = time()
    return guid
end

function Books:CharacterName(guid)
    local c = guid and ML.db.characters[guid]
    return (c and Text(c.name)) or "a character"
end

-------------------------------------------------------------------------------
-- Items
-------------------------------------------------------------------------------
local function ItemIDFromLocation(loc)
    if loc == nil then return nil end
    local id = C_Item and C_Item.GetItemID and Num((ns.SafeCall(C_Item.GetItemID, loc)))      -- RETEST
    if id then return id end
    local link = C_Item and C_Item.GetItemLink and Text((ns.SafeCall(C_Item.GetItemLink, loc)))
    return link and tonumber(link:match("item:(%d+)")) or nil
end

-- item name -> ID, from MendeLedger's name cache (random-suffix names such as
-- "Ivy Orb of the Bear" fall back to the base name)
local byName, byNameCount = nil, -1
function Books:ItemIDByName(name)
    name = Text(name)
    if not name then return nil end
    local names = ML.db.names
    local n = 0
    for _ in pairs(names) do n = n + 1 end
    if not byName or n ~= byNameCount then
        byName, byNameCount = {}, n
        for id, v in pairs(names) do
            if type(id) == "number" and type(v) == "string" then byName[v:sub(2):lower()] = id end
        end
    end
    local lower = name:lower()
    if byName[lower] then return byName[lower] end
    local base = lower:match("^(.-) of .+$")
    if base and byName[base] then return byName[base] end
    -- the game knows items it has cached by name
    local getInstant = C_Item and C_Item.GetItemInfoInstant                                     -- RETEST
    local id = getInstant and Num((ns.SafeCall(getInstant, name)))
    if not id and base then id = getInstant and Num((ns.SafeCall(getInstant, name:match("^(.-) of .+$")))) end
    return id
end

function Books:ItemName(id)
    return id and Ledger:ItemName(id) or nil
end

-------------------------------------------------------------------------------
-- Recording
-------------------------------------------------------------------------------
function Books:Add(r)
    if not ML.db.settings.recordBooks then return nil end
    r.t = r.t or time()
    r.ch = r.ch or self:Character()
    r.h = r.h or Ledger:CurrentRealmKey()
    local tx = DB().tx
    tx[#tx + 1] = r
    self.version = (self.version or 0) + 1
    ML:RequestUIRefresh(nil, true)
    return r
end

-- A commodity purchase recorded at the auction house that an "Auction won"
-- mail now also reports
local function FindUnmailedPurchase(id, name, q, paid, arrival)
    local tx = DB().tx
    for i = #tx, 1, -1 do
        local r = tx[i]
        if r.k == "buy" and r.src == "ah" and not r.mailed and r.q == q
            and math.abs((r.g or 0) - paid) <= math.max(1, paid * 0.01)
            and arrival >= r.t - 300 and arrival <= r.t + 7200
            and ((id and r.id == id) or (name and r.n and r.n:lower() == name:lower())) then
            return r
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- Mail
-------------------------------------------------------------------------------
-- "Auction successful: %s" -> a Lua pattern capturing the item name
local function SubjectPattern(fmt)
    fmt = Text(fmt)
    if not fmt then return nil end
    local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%s", "(.+)")
    return "^" .. p .. "$"
end
Books.SubjectPattern = SubjectPattern

-- One pass over the open mailbox: every auction invoice not seen before
-- becomes a record. Returns the number of new records.
function Books:ScanMail()
    if not ML.db.settings.recordBooks then return 0 end
    local numItems = GetInboxNumItems and Num((ns.SafeCall(GetInboxNumItems)))                 -- RETEST
    if not numItems or numItems <= 0 then return 0 end
    local hasInvoices = type(rawget(_G, "GetInboxInvoiceInfo")) == "function"                   -- RETEST
    local soldPattern = not hasInvoices and SubjectPattern(rawget(_G, "AUCTION_SOLD_MAIL_SUBJECT")) or nil
    local now = time()
    local found = {}
    for i = 1, numItems do
        local h = { ns.SafeCall(GetInboxHeaderInfo, i) }                                          -- RETEST
        local subject, money, daysLeft = Text(h[4]), Num(h[5]) or 0, Num(h[7])
        if daysLeft then
            local arrival = floor(now - (MAIL_DAYS - daysLeft) * 86400)
            if hasInvoices then
                local inv = { ns.SafeCall(GetInboxInvoiceInfo, i) }
                local kind = Text(inv[1])
                if kind == "seller" or kind == "buyer" then
                    local name = Text(inv[2])
                    local bid, deposit, cut = Num(inv[4]) or 0, Num(inv[6]) or 0, Num(inv[7]) or 0
                    local count = Num(inv[11]) or 1
                    local id
                    if kind == "buyer" and GetInboxItemLink then
                        local link = Text((ns.SafeCall(GetInboxItemLink, i, 1)))
                        id = link and tonumber(link:match("item:(%d+)")) or nil
                    end
                    found[#found + 1] = {
                        sig = table.concat({ kind, name or "?", count, bid, deposit, cut }, "|"),
                        arrival = arrival, kind = kind, name = name, id = id, count = count,
                        bid = bid, deposit = deposit, cut = cut, money = money,
                    }
                end
            elseif soldPattern and subject then
                -- no invoices on this client: the subject and the gold still give a sale
                local name = subject:match(soldPattern)
                if name and money > 0 then
                    found[#found + 1] = { sig = "seller|" .. name .. "|" .. money, arrival = arrival, kind = "seller",
                                          name = name, count = nil, bid = money, deposit = 0, cut = 0, money = money }
                end
            end
        end
    end
    -- match against mail already counted, one to one
    local seen = DB().seen
    local used = {}
    local added = 0
    for _, m in ipairs(found) do
        local match
        for j, s in ipairs(seen) do
            if not used[j] and s.s == m.sig and math.abs(s.t - m.arrival) <= MATCH_SECONDS then match = j break end
        end
        if match then
            used[match] = true
        else
            seen[#seen + 1] = { s = m.sig, t = m.arrival }
            used[#seen] = true
            if self:FromMail(m) then added = added + 1 end
        end
    end
    -- forget mail older than any mail can be
    for j = #seen, 1, -1 do
        if seen[j].t < now - SEEN_DAYS * 86400 then table.remove(seen, j) end
    end
    return added
end

function Books:FromMail(m)
    local id = m.id or self:ItemIDByName(m.name)
    if m.kind == "seller" then
        -- the mail's gold is what was received; if it was already taken, work it out
        local received = (m.money and m.money > 0) and m.money or (m.bid - m.cut + m.deposit)
        return self:Add({ t = m.arrival, k = "sale", id = id, n = m.name, q = m.count, g = m.bid, c = m.cut,
                          d = m.deposit, m = received, src = "mail" }) ~= nil
    end
    local dup = FindUnmailedPurchase(id, m.name, m.count, m.bid, m.arrival)
    if dup then
        dup.mailed = true
        return false
    end
    return self:Add({ t = m.arrival, k = "buy", id = id, n = m.name, q = m.count, g = m.bid, src = "mail" }) ~= nil
end

-------------------------------------------------------------------------------
-- Purchases of commodities and deposits, as they happen
-------------------------------------------------------------------------------
local purchase                  -- { id, q, unit, total, confirmed }
local posts = {}                -- posts waiting for AUCTION_HOUSE_AUCTION_CREATED

local function OnStartCommodities(itemID, quantity)
    purchase = { id = Num(itemID), q = Num(quantity) }
end

local function OnConfirmCommodities(itemID, quantity)
    local id = Num(itemID)
    if not purchase or purchase.id ~= id then purchase = { id = id } end
    purchase.confirmQ = Num(quantity) or purchase.q
    purchase.confirmed = GetTime()
end

local function OnPurchaseSucceeded()
    local p = purchase
    purchase = nil
    if not p or not p.confirmed or not p.id then return end
    local q = p.confirmQ or p.q or 1
    local paid = (p.total and p.q == q) and p.total or (p.unit and p.unit * q) or nil
    if not paid then return end
    Books:Add({ k = "buy", id = p.id, n = Books:ItemName(p.id), q = q, g = floor(paid), src = "ah" })
end

local function QueuePost(id, quantity, deposit)
    local post = { id = id, q = Num(quantity) or 1, deposit = Num(deposit), at = GetTime() }
    if ns.eventOK.AUCTION_HOUSE_AUCTION_CREATED then
        posts[#posts + 1] = post
    elseif post.deposit and post.deposit > 0 then
        Books:Add({ k = "deposit", id = id, n = Books:ItemName(id), q = post.q, g = post.deposit, src = "ah" })
    end
end

local function OnPostItem(item, duration, quantity)
    local deposit = C_AuctionHouse and ns.SafeCall(C_AuctionHouse.CalculateItemDeposit, item, duration, quantity)   -- RETEST
    QueuePost(ItemIDFromLocation(item), quantity, deposit)
end

local function OnPostCommodity(item, duration, quantity)
    local id = ItemIDFromLocation(item)
    local deposit = id and C_AuctionHouse and ns.SafeCall(C_AuctionHouse.CalculateCommodityDeposit, id, duration, quantity)   -- RETEST
    QueuePost(id, quantity, deposit)
end

local function OnAuctionCreated()
    local now = GetTime()
    while posts[1] and now - posts[1].at > CREATED_WAIT do table.remove(posts, 1) end   -- never confirmed
    local post = table.remove(posts, 1)
    if post and post.deposit and post.deposit > 0 then
        Books:Add({ k = "deposit", id = post.id, n = Books:ItemName(post.id), q = post.q, g = post.deposit, src = "ah" })
    end
end

function Books:Hook()
    if self.hooked or type(C_AuctionHouse) ~= "table" then return end
    self.hooked = true
    local AH = C_AuctionHouse
    if type(AH.StartCommoditiesPurchase) == "function" then hooksecurefunc(AH, "StartCommoditiesPurchase", OnStartCommodities) end   -- RETEST
    if type(AH.ConfirmCommoditiesPurchase) == "function" then hooksecurefunc(AH, "ConfirmCommoditiesPurchase", OnConfirmCommodities) end
    if type(AH.PostItem) == "function" then hooksecurefunc(AH, "PostItem", OnPostItem) end
    if type(AH.PostCommodity) == "function" then hooksecurefunc(AH, "PostCommodity", OnPostCommodity) end
end

function Books:OnLogin()
    self:Character()
    self:Hook()
end

-------------------------------------------------------------------------------
-- Totals by period
-------------------------------------------------------------------------------
Books.PERIODS = { "day", "week", "month", "quarter", "year" }

-- start time, long label and short label of the period a time falls in
function Books.Period(t, kind)
    local d = date("*t", t)
    if kind == "day" then
        local s = time({ year = d.year, month = d.month, day = d.day, hour = 0 })
        return s, ("%s, %s %d, %d"):format(date("%a", s), date("%b", s), d.day, d.year), ("%s %d"):format(date("%b", s), d.day)
    elseif kind == "week" then
        local offset = (d.wday + 5) % 7                -- weeks start on Monday
        local s = time({ year = d.year, month = d.month, day = d.day - offset, hour = 0 })
        local w = date("*t", s)
        return s, ("Week of %s %d, %d"):format(date("%b", s), w.day, w.year), ("%s %d"):format(date("%b", s), w.day)
    elseif kind == "month" then
        local s = time({ year = d.year, month = d.month, day = 1, hour = 0 })
        return s, ("%s %d"):format(date("%B", s), d.year), date("%b", s)
    elseif kind == "quarter" then
        local q = floor((d.month - 1) / 3) + 1
        local s = time({ year = d.year, month = (q - 1) * 3 + 1, day = 1, hour = 0 })
        return s, ("Q%d %d"):format(q, d.year), ("Q%d '%02d"):format(q, d.year % 100)
    end
    local s = time({ year = d.year, month = 1, day = 1, hour = 0 })
    return s, tostring(d.year), tostring(d.year)
end

-- Records in a scope: "house" (the auction house shown), "char" (this
-- character) or "all"
function Books:Records(scope, house)
    local out, me = {}, nil
    if scope == "char" then me = self:Character() end
    for _, r in ipairs(DB().tx) do
        if scope == "all" or (scope == "char" and r.ch == me) or (scope == "house" and r.h == house) then
            out[#out + 1] = r
        end
    end
    table.sort(out, function(a, b) return a.t > b.t end)
    return out
end

local function Totals()
    return { income = 0, gross = 0, cut = 0, returned = 0, purchases = 0, deposits = 0, sold = 0, bought = 0, n = 0, tx = {} }
end

local function AddTo(p, r)
    p.n = p.n + 1
    p.tx[#p.tx + 1] = r
    if r.k == "sale" then
        p.income = p.income + (r.m or 0)
        p.gross = p.gross + (r.g or 0)
        p.cut = p.cut + (r.c or 0)
        p.returned = p.returned + (r.d or 0)
        p.sold = p.sold + (r.q or 1)
    elseif r.k == "buy" then
        p.purchases = p.purchases + (r.g or 0)
        p.bought = p.bought + (r.q or 1)
    elseif r.k == "deposit" then
        p.deposits = p.deposits + (r.g or 0)
    end
end

-- Income is gold received from sales (after the auction house's cut, with
-- returned deposits); spending is purchases plus deposits paid; profit is
-- the difference.
local function Finish(p)
    p.spent = p.purchases + p.deposits
    p.profit = p.income - p.spent
    return p
end

-- Periods of a kind, newest first, each with its totals and records
function Books:Summaries(kind, scope, house)
    local byStart, list = {}, {}
    for _, r in ipairs(self:Records(scope, house)) do
        local start, label, short = Books.Period(r.t, kind)
        local p = byStart[start]
        if not p then
            p = Totals()
            p.start, p.label, p.short = start, label, short
            byStart[start] = p
            list[#list + 1] = p
        end
        AddTo(p, r)
    end
    table.sort(list, function(a, b) return a.start > b.start end)
    for _, p in ipairs(list) do Finish(p) end
    return list
end

-- Totals of the period that contains now
function Books:Current(kind, scope, house)
    local start, label = Books.Period(time(), kind)
    for _, p in ipairs(self:Summaries(kind, scope, house)) do
        if p.start == start then return p end
    end
    local p = Finish(Totals())
    p.start, p.label = start, label
    return p
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local mailTimer
ns.On("MAIL_INBOX_UPDATE", function()                                   -- RETEST
    if not ML.db.settings.recordBooks then return end
    if mailTimer then mailTimer:Cancel() end
    mailTimer = C_Timer.NewTimer(0.3, function()
        mailTimer = nil
        Books:ScanMail()
    end)
end)
ns.On("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)       -- RETEST
    if purchase then purchase.unit, purchase.total = Num(unitPrice), Num(totalPrice) end
end)
ns.On("COMMODITY_PURCHASE_SUCCEEDED", OnPurchaseSucceeded)
ns.On("COMMODITY_PURCHASE_FAILED", function() purchase = nil end)
ns.On("AUCTION_HOUSE_AUCTION_CREATED", OnAuctionCreated)               -- RETEST
