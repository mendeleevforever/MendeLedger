local addonName, ns = ...
-- UI.lua
-- The MendeLedger window, drawn in the same palette and layout as Looking For
-- Work (dark window, layered gold trim, title plate on the top edge, icon tabs
-- down the right-hand edge):
--   * Ledger tab: search box, Filter button and every recorded item grouped
--     under collapsible item-type bars on the left; on the right, the price
--     graph (daily low line, low-high band, quantity bars, hover for a day),
--     a summary for the chosen range and the daily records
--   * Options tab: recording, compression, how long to keep history, storage
--     used, realms in the ledger and a client capability check
-- None of these frames are protected. The only protected UI MendeLedger
-- touches is the Blizzard Settings panel, through ns.AfterCombat.

local ML, Ledger = ns.ML, ns.Ledger

local W, H          = 880, 660
local TAB, TAB_GAP  = 40, 4
local HEADER_Y      = -44
local CONTENT_TOP   = -90
local CONTENT_BOT   = 52
local LEFT_X, LEFT_R = 16, 332            -- item list panel
local RIGHT_X       = 344                 -- detail panel (to W - 16)
local LIST_X        = LEFT_X + 4
local LIST_TOP      = CONTENT_TOP - 30
local LIST_W        = LEFT_R - 24 - LIST_X
local ROW_H         = 22
local DW            = W - 16 - RIGHT_X    -- detail panel width
local GW, GH        = DW - 24, 220        -- graph
local PL, PR, PT, PB = 58, 10, 10, 22     -- plot insets inside the graph
local PW, PH        = GW - PL - PR, GH - PT - PB
local MAX_COLS      = 120                 -- more days than this are grouped into spans
local DAY_ROW_H     = 20
local RANGE_W       = 7 * 38 + 6 * 3
local LEDGER_ICON   = 132763
local OPTIONS_ICON  = "Interface\\Icons\\INV_Misc_Gear_01"
local QUESTION      = "Interface\\Icons\\INV_Misc_QuestionMark"
local OTHER         = "Other"

-------------------------------------------------------------------------------
-- Palette and widgets (same look as Looking For Work)
-------------------------------------------------------------------------------
local C = {
    bg        = { 0.118, 0.082, 0.051 },
    gold      = { 0.541, 0.416, 0.173 },
    goldLight = { 0.722, 0.569, 0.235 },
    outline   = { 0.169, 0.118, 0.055 },
    inner     = { 0.290, 0.212, 0.094 },
    rule      = { 0.420, 0.314, 0.137 },
    header    = { 0.831, 0.627, 0.090 },
    text      = { 0.902, 0.839, 0.682 },
    muted     = { 0.612, 0.553, 0.439 },
    legend    = { 0.720, 0.650, 0.520 },
    plate     = { 0.165, 0.114, 0.063 },
    field     = { 0.071, 0.047, 0.027 },
    stripe    = { 0.353, 0.263, 0.125 },
    up        = { 0.25, 1.00, 0.25 },
    down      = { 1.00, 0.38, 0.25 },
}
local DOT = "   |cff7d705a•|r   "
local GREY = "|cff9d9d9d"

local QUALITY = {
    [0] = { 0.62, 0.62, 0.62 }, { 1, 1, 1 }, { 0.12, 1, 0 }, { 0, 0.44, 0.87 },
    { 0.64, 0.21, 0.93 }, { 1, 0.5, 0 }, { 0.9, 0.8, 0.5 }, { 0, 0.8, 1 },
}
local function QualityRGB(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]        -- RETEST
    if type(c) == "table" and c.r then return { c.r, c.g, c.b } end
    return QUALITY[q or 1] or QUALITY[1]
end

local function SetColor(obj, rgb, a) obj:SetTextColor(rgb[1], rgb[2], rgb[3], a or 1) end
local function Hex(rgb) return ("|cff%02x%02x%02x"):format(rgb[1] * 255, rgb[2] * 255, rgb[3] * 255) end

local function AddBorder(frame, layer, rgb, alpha, thickness, inset)
    local function edge()
        local t = frame:CreateTexture(nil, layer)
        t:SetColorTexture(rgb[1], rgb[2], rgb[3], alpha)
        return t
    end
    local top, bottom, left, right = edge(), edge(), edge(), edge()
    top:SetPoint("TOPLEFT", inset, -inset)
    top:SetPoint("TOPRIGHT", -inset, -inset)
    top:SetHeight(thickness)
    bottom:SetPoint("BOTTOMLEFT", inset, inset)
    bottom:SetPoint("BOTTOMRIGHT", -inset, inset)
    bottom:SetHeight(thickness)
    left:SetPoint("TOPLEFT", inset, -inset)
    left:SetPoint("BOTTOMLEFT", inset, inset)
    left:SetWidth(thickness)
    right:SetPoint("TOPRIGHT", -inset, -inset)
    right:SetPoint("BOTTOMRIGHT", -inset, inset)
    right:SetWidth(thickness)
    return { top, bottom, left, right }
end

local function SetEdgeColor(edges, rgb, a)
    for _, t in ipairs(edges) do t:SetColorTexture(rgb[1], rgb[2], rgb[3], a or 1) end
end

local function SetEdgesShown(edges, shown)
    for _, t in ipairs(edges) do t:SetShown(shown) end
end

local function SavePosition(f, posKey)
    local p, _, rp, x, y = f:GetPoint()
    if p and ML.db then ML.db.positions[posKey] = { p, rp, x, y } end
end

local function PlaceFrame(f, posKey)
    local pos = ML.db and ML.db.positions[posKey]
    f:ClearAllPoints()
    if type(pos) == "table" and pos[1] then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint("CENTER", UIParent, "CENTER", -20, 20)
    end
end

local function MakeWindow(globalName, w, h, posKey)
    local f = CreateFrame("Frame", globalName, UIParent)
    f:SetSize(w, h)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition(self, posKey) end)
    PlaceFrame(f, posKey)
    f:Hide()
    tinsert(UISpecialFrames, globalName)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], 0.97)
    bg:SetAllPoints()
    AddBorder(f, "BORDER",  C.outline, 1, 2, -2)
    AddBorder(f, "BORDER",  C.gold,    1, 3,  0)
    AddBorder(f, "ARTWORK", C.inner,   1, 1,  3)

    local plate = CreateFrame("Frame", nil, f)
    plate:SetSize(300, 34)
    plate:SetPoint("TOP", 0, 18)
    plate:SetFrameLevel(f:GetFrameLevel() + 5)
    plate:EnableMouse(true)
    plate:RegisterForDrag("LeftButton")
    plate:SetScript("OnDragStart", function() f:StartMoving() end)
    plate:SetScript("OnDragStop", function() f:StopMovingOrSizing(); SavePosition(f, posKey) end)
    local pbg = plate:CreateTexture(nil, "BACKGROUND")
    pbg:SetColorTexture(C.plate[1], C.plate[2], C.plate[3], 1)
    pbg:SetAllPoints()
    AddBorder(plate, "BORDER", C.outline,   1, 2, -2)
    AddBorder(plate, "BORDER", C.goldLight, 1, 2,  0)
    local title = plate:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", 0, 0)
    title:SetTextColor(1, 0.82, 0)
    if title.SetWordWrap then title:SetWordWrap(false) end
    f.plate, f.title = plate, title

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")    -- RETEST
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)

    f.info = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.info:SetPoint("TOP", 0, -24)
    f.info:SetWidth(w - 160)
    if f.info.SetWordWrap then f.info:SetWordWrap(false) end
    SetColor(f.info, C.legend)
    return f
end

local function SetWindowTitle(f, text)
    f.title:SetText(text)
    f.plate:SetWidth(math.max(260, f.title:GetStringWidth() + 60))
end

local function AddFooterRule(f, y)
    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 1)
    rule:SetPoint("BOTTOMLEFT", 20, y)
    rule:SetPoint("BOTTOMRIGHT", -20, y)
    rule:SetHeight(1)
    return rule
end

local function AddSection(parent, text, y, x1, x2)
    x1, x2 = x1 or 20, x2 or -20
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", x1 + 2, y)
    fs:SetJustifyH("LEFT")
    SetColor(fs, C.header)
    fs:SetText(text)
    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.55)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", x1, y - 16)
    rule:SetPoint("TOPRIGHT", x2, y - 16)
    return fs, rule
end

local function AddLabel(parent, text, font, rgb)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    fs:SetJustifyH("LEFT")
    SetColor(fs, rgb or C.text)
    fs:SetText(text or "")
    return fs
end

local function NoWrap(fs)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    return fs
end

local function AddFieldBox(parent, left, top, right, bottom)
    local t = parent:CreateTexture(nil, "BACKGROUND", nil, 1)
    t:SetColorTexture(C.field[1], C.field[2], C.field[3], 0.9)
    t:SetPoint("TOPLEFT", left, top)
    t:SetPoint("BOTTOMRIGHT", right, bottom)
    local function Edge(p1, p2, w, h)
        local e = parent:CreateTexture(nil, "BORDER")
        e:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 1)
        e:SetPoint(p1, t, p1)
        e:SetPoint(p2, t, p2)
        if w then e:SetWidth(w) end
        if h then e:SetHeight(h) end
    end
    Edge("TOPLEFT", "TOPRIGHT", nil, 1)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    Edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    Edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
    return t
end

local function AddPlaceholder(eb, text)
    local ph = eb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ph:SetPoint("LEFT", 22, 0)
    SetColor(ph, C.muted)
    ph:SetText(text)
    local function Update()
        if eb:GetText() == "" and not eb:HasFocus() then ph:Show() else ph:Hide() end
    end
    eb:HookScript("OnTextChanged", Update)
    eb:HookScript("OnEditFocusGained", Update)
    eb:HookScript("OnEditFocusLost", Update)
    Update()
    return ph
end

-- Search box with a magnifying glass
local function MakeSearchBox(globalName, parent, w)
    local eb = CreateFrame("EditBox", globalName, parent)
    eb:SetSize(w, 22)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal or GameFontHighlight)
    eb:SetTextInsets(20, 18, 0, 0)
    eb:SetMaxLetters(60)
    SetColor(eb, C.text)
    local bg = eb:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.03, 0.02, 0.01, 0.95)
    local edges = AddBorder(eb, "BORDER", C.rule, 1, 1, 0)
    local glass = eb:CreateTexture(nil, "OVERLAY")
    glass:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    glass:SetSize(14, 14)
    glass:SetPoint("LEFT", 4, -1)
    glass:SetVertexColor(C.muted[1], C.muted[2], C.muted[3])
    local clear = CreateFrame("Button", nil, eb)
    clear:SetSize(14, 14)
    clear:SetPoint("RIGHT", -3, 0)
    local x = clear:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    x:SetPoint("CENTER")
    x:SetText("x")
    SetColor(x, C.muted)
    clear:SetScript("OnClick", function() eb:SetText(""); eb:ClearFocus() end)
    clear:Hide()
    eb:HookScript("OnTextChanged", function(self) clear:SetShown(self:GetText() ~= "") end)
    eb:HookScript("OnEditFocusGained", function() SetEdgeColor(edges, C.goldLight); glass:SetVertexColor(1, 0.82, 0) end)
    eb:HookScript("OnEditFocusLost", function() SetEdgeColor(edges, C.rule); glass:SetVertexColor(C.muted[1], C.muted[2], C.muted[3]) end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return eb
end

local function FlatButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h or 18)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(C.plate[1], C.plate[2], C.plate[3], 1)
    b.edges = AddBorder(b, "BORDER", C.gold, 1, 1, 0)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.25)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER", 0, 0)
    SetColor(fs, C.header)
    fs:SetText(text)
    b.label = fs
    b:SetScript("OnMouseDown", function() fs:SetPoint("CENTER", 1, -1) end)
    b:SetScript("OnMouseUp", function() fs:SetPoint("CENTER", 0, 0) end)
    return b
end

local function SetFlatSelected(b, selected)
    local c = selected and C.stripe or C.plate
    b.bg:SetColorTexture(c[1], c[2], c[3], 1)
    SetEdgeColor(b.edges, selected and { 1, 0.82, 0.25 } or C.gold)
    SetColor(b.label, selected and { 1, 1, 1 } or C.header)
end

local function MenuButton(parent, text, w)
    local b = CreateFrame("Button", nil, parent, "GameMenuButtonTemplate")   -- RETEST
    b:SetSize(w or 110, 26)
    b:SetText(text)
    return b
end

local function AddHoverTip(widget, title, body)
    widget:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(title, 1, 0.82, 0)
        if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function MakeCheck(parent, x, y, text, tipTitle, tipBody, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")   -- RETEST
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", x, y)
    local label = AddLabel(cb, text, "GameFontNormal", C.text)
    label:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    if tipTitle then AddHoverTip(cb, tipTitle, tipBody) end
    return cb
end

local function MakeScroll(globalName, parent, childWidth)
    local scroll = CreateFrame("ScrollFrame", globalName, parent, "UIPanelScrollFrameTemplate")   -- RETEST
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(childWidth, 10)
    scroll:SetScrollChild(child)
    return scroll, child
end

-- A scrolling list that only creates frames for the rows on screen, so a list
-- of 7,000 items costs the same as a list of 20. Redraws on scroll events
-- (OnVerticalScroll covers the wheel, the scroll bar and SetVerticalScroll).
--   makeRow(i): create pooled row i      fill(row, item, index): show one item
local function AttachVirtualList(scroll, child, rowH, makeRow, fill)
    local list = { data = {}, rows = {} }
    function list:Render()
        local offset = scroll:GetVerticalScroll() or 0
        local first = math.floor(offset / rowH) + 1
        local visible = math.ceil((scroll:GetHeight() or 200) / rowH) + 1
        for i = 1, visible do
            local idx = first + i - 1
            local item = self.data[idx]
            local row = self.rows[i]
            if item and not row then row = makeRow(i); self.rows[i] = row end
            if row then
                if item then
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(idx - 1) * rowH)
                    fill(row, item, idx)
                    row:Show()
                else
                    row:Hide()
                    row.item = nil
                end
            end
        end
        for i = visible + 1, #self.rows do self.rows[i]:Hide(); self.rows[i].item = nil end
    end
    function list:SetData(data, resetScroll)
        self.data = data
        child:SetHeight(math.max(10, #data * rowH))
        if resetScroll then scroll:SetVerticalScroll(0) end
        self:Render()
    end
    scroll:HookScript("OnVerticalScroll", function() list:Render() end)
    scroll:HookScript("OnSizeChanged", function() list:Render() end)
    return list
end

local function StripeRow(row, idx)
    if not row.stripe then
        row.stripe = row:CreateTexture(nil, "BACKGROUND")
        row.stripe:SetAllPoints()
    end
    row.stripe:SetColorTexture(C.stripe[1], C.stripe[2], C.stripe[3], (idx % 2 == 0) and 0.18 or 0.06)
end

local function Percent(x)
    if not x then return GREY .. "—|r" end
    local p = x * 100
    local col = (p > 0.05) and C.up or ((p < -0.05) and C.down or C.muted)
    local text = (math.abs(p) >= 100) and ("%+.0f%%"):format(p) or ("%+.1f%%"):format(p)
    return Hex(col) .. text .. "|r"
end

-------------------------------------------------------------------------------
-- Item helpers
-------------------------------------------------------------------------------
local function DisplayName(e)
    if e.label then return e.label end
    if e.kind == "pet" then return ("Battle pet #%d"):format(e.id or 0) end
    return ("Item #%s"):format(tostring(e.id or e.key))
end

local function ItemLink(e)
    if e.kind == "pet" or not e.id or not (C_Item and C_Item.GetItemInfo) then return nil end
    local _, link = ns.SafeCall(C_Item.GetItemInfo, e.id)
    return ns.Text(link)
end

function ML:LinkItem(e)
    local link = ItemLink(e)
    if link and HandleModifiedItemClick then                       -- RETEST
        HandleModifiedItemClick(link)
    elseif e.id then
        Ledger:QueueName(e.id, true)
        ns.Print("that item is still loading; try again in a moment.")
    end
end

local function AddItemTooltip(owner, e)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local shown = false
    if e.kind ~= "pet" and e.id then shown = pcall(GameTooltip.SetItemByID, GameTooltip, e.id) end   -- RETEST
    if not shown then GameTooltip:AddLine(DisplayName(e), 1, 1, 1) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Latest price", ns.Coins(e.m), C.muted[1], C.muted[2], C.muted[3], 1, 1, 1)
    GameTooltip:AddDoubleLine("7-day change", Percent(e.change), C.muted[1], C.muted[2], C.muted[3], 1, 1, 1)
    local profit, vendor = Ledger:VendorProfit(e)
    if profit and profit > 0 then
        GameTooltip:AddDoubleLine("Vendor profit", "|cff40ff40+|r" .. ns.Coins(profit), C.muted[1], C.muted[2], C.muted[3], 1, 1, 1)
    elseif profit then
        GameTooltip:AddDoubleLine("Vendor profit", GREY .. "none (vendor pays " .. ns.PlainMoney(vendor) .. ")|r", C.muted[1], C.muted[2], C.muted[3], 1, 1, 1)
    elseif vendor == 0 then
        GameTooltip:AddDoubleLine("Vendor profit", GREY .. "vendors won't buy it|r", C.muted[1], C.muted[2], C.muted[3], 1, 1, 1)
    end
    local m = C.muted
    local deProfit, deValue, deState, partial, estimated = Ledger:DisenchantProfit(Ledger:ShownRealm(), e)
    local note = (partial and " *" or "") .. (estimated and (GREY .. " (estimate)|r") or "")
    if deProfit and deProfit > 0 then
        GameTooltip:AddDoubleLine("Disenchant profit", "|cff40ff40+|r" .. ns.Coins(deProfit) .. note, m[1], m[2], m[3], 1, 1, 1)
    elseif deProfit then
        GameTooltip:AddDoubleLine("Disenchant profit", GREY .. "none (disenchants for about " .. ns.PlainMoney(deValue) .. ")|r" .. note, m[1], m[2], m[3], 1, 1, 1)
    elseif deState == "cannot" then
        GameTooltip:AddDoubleLine("Disenchant profit", GREY .. "can't be disenchanted|r", m[1], m[2], m[3], 1, 1, 1)
    elseif deState == "noprice" then
        GameTooltip:AddDoubleLine("Disenchant profit", GREY .. "its materials have no prices yet|r", m[1], m[2], m[3], 1, 1, 1)
    elseif deState == "nodata" then
        GameTooltip:AddDoubleLine("Disenchant profit", GREY .. "no disenchant data for its item level|r", m[1], m[2], m[3], 1, 1, 1)
    end
    if partial and deState == "ok" then
        GameTooltip:AddLine("* some of its materials have no price yet, so the real value is higher", m[1], m[2], m[3], true)
    end
    GameTooltip:AddDoubleLine("Recorded", ("%s day%s, %s – %s"):format(ns.Commas(e.count), e.count == 1 and "" or "s",
        ns.DayLabel(e.first), ns.DayLabel(e.last)), C.muted[1], C.muted[2], C.muted[3], 1, 1, 1)
    GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- Main window
-------------------------------------------------------------------------------
function ML:PlaceMainFrame()
    if self.frame then PlaceFrame(self.frame, "main") end
end

function ML:CreateMainFrame()
    if self.frame then return self.frame end
    local f = MakeWindow("MendeLedgerFrame", W, H, "main")
    SetWindowTitle(f, "MendeLedger")
    if f.SetClampRectInsets then f:SetClampRectInsets(0, TAB + 6, 20, 0) end
    self.frame = f

    self:CreateTabs(f)
    self:CreateLedgerView(f)
    self:CreateOptionsView(f)

    AddFooterRule(f, 46)
    f.legend = NoWrap(AddLabel(f, "", "GameFontNormalSmall", C.legend))
    f.legend:SetPoint("BOTTOMLEFT", 22, 20)
    f.legend:SetWidth(W - 180)
    local closeBtn = MenuButton(f, "Close", 110)
    closeBtn:SetPoint("BOTTOMRIGHT", -20, 13)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnShow", function()
        ML:SelectTab(ML.currentTab or ML.db.settings.lastTab)
    end)
    f:SetScript("OnHide", function()
        if f.search then f.search:ClearFocus() end
        if ML.dropList then ML.dropList:Hide() end
        GameTooltip:Hide()
    end)
    return f
end

function ML:Toggle()
    local f = self:CreateMainFrame()
    if f:IsShown() then f:Hide() else f:Show(); f:Raise() end
end

function ML:Open(tab)
    local f = self:CreateMainFrame()
    if tab then self.currentTab = tab end
    if f:IsShown() then
        if tab then self:SelectTab(tab) end
    else
        f:Show()
    end
    f:Raise()
end

function ML:OpenSearch(text)
    self:Open("ledger")
    self.frame.search:SetText(ns.Trim(text or ""))
end

function ML:ShowRealm(key)
    self.db.settings.realm = key
    self.selectedKey = nil
    self:RequestUIRefresh(0)
end

local refreshTimer
function ML:RequestUIRefresh(delay)
    local f = self.frame
    if not f or not f:IsShown() then return end
    if refreshTimer then return end
    refreshTimer = C_Timer.NewTimer(delay or 0.15, function()
        refreshTimer = nil
        if not f:IsShown() then return end
        if self.currentTab == "options" then self:RefreshOptions() else self:RefreshLedger() end
        self:UpdateInfoLine()
    end)
end

local lastProgress = 0
function ML:OnJobProgress()
    local f = self.frame
    if not f or not f:IsShown() or GetTime() - lastProgress < 0.25 then return end
    lastProgress = GetTime()
    self:UpdateInfoLine()
    if self.currentTab == "options" then self:UpdateRecordingStatus() end
    local job = ns.CurrentJob()
    if job and self.currentTab == "ledger" and (job.name == "index" or (job.name == "tooltips" and self.searchActive)) then
        self:RefreshLedger()
    end
end

function ML:UpdateInfoLine()
    local f = self.frame
    if not f then return end
    local job = ns.CurrentJob()
    if job and job.Progress then
        local done, total = job:Progress()
        f.info:SetText(("%s  —  %s of %s items"):format(job.label or job.name, ns.Commas(done), ns.Commas(total)))
        return
    end
    local key = Ledger:ShownRealm()
    local realm = key and Ledger:Realm(key)
    if not realm then
        f.info:SetText(Ledger:AuctionatorPresent() and "Nothing recorded yet" or "Auctionator isn't loaded")
        return
    end
    local st = realm.stats or {}
    local parts = { Ledger:RealmName(key) .. "  —  " .. ns.Commas(st.items or 0) .. " items" }
    if st.first then parts[#parts + 1] = ns.DayLabel(st.first) .. " – " .. ns.DayDate(st.last) end
    parts[#parts + 1] = "recorded " .. ns.Ago(realm.lastRecord)
    f.info:SetText(table.concat(parts, "  •  "))
end

-------------------------------------------------------------------------------
-- Tabs down the right edge
-------------------------------------------------------------------------------
local TAB_INFO = {
    options = { title = "Options", body = "Recording, compression, how long to keep history, storage and auction houses" },
    ledger  = { title = "Ledger", body = "Search recorded items and graph their price history" },
}

local function CreateTab(f, key, icon, y)
    local b = CreateFrame("Button", nil, f)
    b:SetSize(TAB, TAB)
    b.y = y
    b:SetPoint("TOPLEFT", f, "TOPRIGHT", 1, y)
    b:SetFrameLevel(f:GetFrameLevel() + 2)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.plate[1], C.plate[2], C.plate[3], 1)
    b.outline = AddBorder(b, "BORDER", C.outline, 1, 2, -2)
    b.edges = AddBorder(b, "BORDER", C.gold, 1, 2, 0)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    b.icon:SetTexture(icon)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 3, -3)
    hl:SetPoint("BOTTOMRIGHT", -3, 3)
    hl:SetColorTexture(1, 0.9, 0.6, 0.18)
    b.glow = b:CreateTexture(nil, "OVERLAY")
    b.glow:SetPoint("TOPLEFT", -3, 3)
    b.glow:SetPoint("BOTTOMRIGHT", 3, -3)
    b.glow:SetColorTexture(1, 0.82, 0.2, 0.18)
    b.glow:Hide()
    b.key = key
    b:SetScript("OnClick", function(self) ML:SelectTab(self.key) end)
    b:SetScript("OnEnter", function(self)
        local info = TAB_INFO[self.key]
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(info.title, 1, 0.82, 0)
        GameTooltip:AddLine(info.body, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

function ML:CreateTabs(f)
    f.tabs = {}
    local y = -22
    f.tabs.options = CreateTab(f, "options", OPTIONS_ICON, y)
    y = y - TAB - TAB_GAP - 8
    f.tabs.ledger = CreateTab(f, "ledger", LEDGER_ICON, y)
end

function ML:UpdateTabs()
    local f = self.frame
    if not f then return end
    for key, b in pairs(f.tabs) do
        local selected = key == self.currentTab
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f, "TOPRIGHT", selected and -2 or 1, b.y)
        SetEdgeColor(b.edges, selected and { 1, 0.82, 0.25 } or C.gold)
        b.glow:SetShown(selected)
    end
end

function ML:SelectTab(key)
    local f = self:CreateMainFrame()
    if key ~= "options" then key = "ledger" end
    self.currentTab = key
    self.db.settings.lastTab = key
    if self.dropList then self.dropList:Hide() end
    GameTooltip:Hide()
    if key == "options" then
        f.ledgerView:Hide()
        f.optionsView:Show()
        f.legend:SetText(("MendeLedger %s"):format(ML.VERSION) .. DOT .. "Prices come from Auctionator's scans" .. DOT .. "/mendel help")
        self:RefreshOptions()
    else
        f.optionsView:Hide()
        f.ledgerView:Show()
        f.legend:SetText("Click an item to graph it" .. DOT .. "Shift-click to link it" .. DOT .. "Hover the graph for each day's prices")
        self:RefreshLedger(true)
    end
    self:UpdateInfoLine()
    self:UpdateTabs()
end

-------------------------------------------------------------------------------
-- Ledger view: header, item list, detail panel with the graph
-------------------------------------------------------------------------------
local RANGES = { { 1, "24H" }, { 3, "3D" }, { 7, "7D" }, { 30, "30D" }, { 90, "90D" }, { 365, "1Y" }, { 0, "All" } }

function ML:CreateLedgerView(f)
    local lv = CreateFrame("Frame", nil, f)
    lv:SetAllPoints()
    f.ledgerView = lv

    -- Header: item icon, name, type line, coverage bar and range buttons
    local iconBtn = CreateFrame("Button", nil, lv)
    iconBtn:SetSize(38, 38)
    iconBtn:SetPoint("TOPLEFT", 18, HEADER_Y + 1)
    AddBorder(iconBtn, "BORDER", C.gold, 1, 1, 0)
    lv.icon = iconBtn:CreateTexture(nil, "ARTWORK")
    lv.icon:SetPoint("TOPLEFT", 2, -2)
    lv.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    lv.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    iconBtn:SetScript("OnEnter", function(self) if ML.selectedEntry then AddItemTooltip(self, ML.selectedEntry) end end)
    iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    iconBtn:SetScript("OnClick", function()
        local e = ML.selectedEntry
        if e and IsModifiedClick and (IsModifiedClick("CHATLINK") or IsModifiedClick("DRESSUP")) then ML:LinkItem(e) end
    end)

    lv.title = NoWrap(AddLabel(lv, "", "GameFontNormalLarge", C.header))
    lv.title:SetPoint("TOPLEFT", 66, HEADER_Y - 1)
    lv.title:SetWidth(W - 66 - 310)

    lv.stats = NoWrap(AddLabel(lv, "", "GameFontNormalSmall", C.legend))
    lv.stats:SetPoint("TOPRIGHT", -22, HEADER_Y - 4)
    lv.stats:SetJustifyH("RIGHT")
    lv.stats:SetWidth(280)

    local bar = CreateFrame("StatusBar", nil, lv)
    bar:SetPoint("TOPLEFT", 66, HEADER_Y - 22)
    bar:SetPoint("TOPRIGHT", -(20 + RANGE_W + 10), HEADER_Y - 22)
    bar:SetHeight(16)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.86, 0.36, 0.12)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local barBg = bar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(0.03, 0.02, 0.01, 0.95)
    AddBorder(bar, "OVERLAY", C.rule, 1, 1, -1)
    lv.barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lv.barText:SetPoint("CENTER", 0, 0)
    lv.bar = bar

    lv.rangeButtons = {}
    for i = #RANGES, 1, -1 do
        local r = RANGES[i]
        local b = FlatButton(lv, r[2], 38, 18)
        b:SetPoint("TOPRIGHT", -20 - (#RANGES - i) * 41, HEADER_Y - 21)
        b.days = r[1]
        b:SetScript("OnClick", function(self)
            ML.db.settings.range = self.days
            ML:UpdateRangeButtons()
            ML:RefreshDetail()
        end)
        AddHoverTip(b, (r[1] == 1 and "Last 24 hours") or (r[1] > 0 and ("Last %d days"):format(r[1])) or "All recorded history",
            r[1] > 0 and r[1] <= 7 and "Range shown in the graph, the summary and the records. Up to 7 days, every Auctionator scan can be shown instead of one point per day."
            or "Range shown in the graph, the summary and the daily records.")
        lv.rangeButtons[i] = b
    end

    -- Left panel: search, filter and the item list
    AddFieldBox(lv, LEFT_X, CONTENT_TOP, -(W - LEFT_R), CONTENT_BOT)

    local search = MakeSearchBox("MendeLedgerSearchBox", lv, 214)
    search:SetPoint("TOPLEFT", LEFT_X + 6, CONTENT_TOP - 5)
    AddPlaceholder(search, "Search names and tooltips")
    search:HookScript("OnTextChanged", function() ML:RequestUIRefresh(0.12) end)
    AddHoverTip(search, "Search", "Matches item names, item types and tooltip text: weapon and armor types, slots, stats, effects and set bonuses. "
        .. "Every word must match; put a phrase in quotes to match it exactly, like \"increased defense\". A number on its own finds that item ID. "
        .. "With the box selected, shift-click an item in your bags to search for it.")
    f.search = search

    local filter = FlatButton(lv, "Filter  |cffffd100>|r", 84, 22)
    filter:SetPoint("TOPLEFT", LEFT_X + 226, CONTENT_TOP - 5)
    filter:SetScript("OnClick", function(self) ML:ToggleFilterMenu(self) end)

    local scroll, child = MakeScroll("MendeLedgerItemScroll", lv, LIST_W)
    scroll:SetPoint("TOPLEFT", LIST_X, LIST_TOP)
    scroll:SetPoint("BOTTOMRIGHT", lv, "BOTTOMLEFT", LEFT_R - 24, CONTENT_BOT + 4)
    lv.itemList = AttachVirtualList(scroll, child, ROW_H, function() return ML:MakeItemRow(child) end,
        function(row, e) ML:FillItemRow(row, e) end)

    lv.listEmpty = AddLabel(lv, "", "GameFontNormal", C.muted)
    lv.listEmpty:SetPoint("TOPLEFT", LIST_X + 10, LIST_TOP - 30)
    lv.listEmpty:SetWidth(LIST_W - 20)
    lv.listEmpty:SetJustifyH("CENTER")
    if lv.listEmpty.SetSpacing then lv.listEmpty:SetSpacing(3) end

    -- Right panel: graph, summary, daily records
    AddFieldBox(lv, RIGHT_X, CONTENT_TOP, -16, CONTENT_BOT)
    local d = CreateFrame("Frame", nil, lv)
    d:SetPoint("TOPLEFT", RIGHT_X, CONTENT_TOP)
    d:SetPoint("BOTTOMRIGHT", -16, CONTENT_BOT)
    lv.detail = d
    self:CreateGraph(d)
    self:CreateSummary(d)
end

function ML:UpdateRangeButtons()
    local lv = self.frame and self.frame.ledgerView
    if not lv then return end
    for _, b in ipairs(lv.rangeButtons) do SetFlatSelected(b, b.days == self.db.settings.range) end
end

-------------------------------------------------------------------------------
-- Item list rows
-------------------------------------------------------------------------------
function ML:MakeItemRow(child)
    local row = CreateFrame("Button", nil, child)
    row:SetSize(LIST_W, ROW_H)
    row:RegisterForClicks("LeftButtonUp")

    -- type header look: dark plate with gold edge, gold text and -/+
    row.hbg = row:CreateTexture(nil, "BACKGROUND")
    row.hbg:SetPoint("TOPLEFT", 0, -1)
    row.hbg:SetPoint("BOTTOMRIGHT", 0, 1)
    row.hbg:SetColorTexture(0.22, 0.14, 0.06, 1)
    row.hedges = {}
    local function hedge(p1, p2, w, h)
        local e = row:CreateTexture(nil, "BORDER")
        e:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 1)
        e:SetPoint(p1, row.hbg, p1)
        e:SetPoint(p2, row.hbg, p2)
        if w then e:SetWidth(w) end
        if h then e:SetHeight(h) end
        row.hedges[#row.hedges + 1] = e
    end
    hedge("TOPLEFT", "TOPRIGHT", nil, 1)
    hedge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    hedge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    hedge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
    row.htext = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.htext:SetPoint("LEFT", 8, 0)
    row.htext:SetPoint("RIGHT", -60, 0)
    row.htext:SetJustifyH("LEFT")
    SetColor(row.htext, C.header)
    row.htoggle = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    row.htoggle:SetPoint("RIGHT", -8, 0)
    SetColor(row.htoggle, C.header)
    row.hcount = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.hcount:SetPoint("RIGHT", -26, 0)
    SetColor(row.hcount, C.muted)

    -- item look
    row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 2)
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.32)
    row.selBar = row:CreateTexture(nil, "ARTWORK")
    row.selBar:SetPoint("TOPLEFT")
    row.selBar:SetPoint("BOTTOMLEFT")
    row.selBar:SetWidth(2)
    row.selBar:SetColorTexture(1, 0.82, 0.2, 1)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 6, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.text = NoWrap(row:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
    row.text:SetPoint("LEFT", 28, 0)
    row.text:SetPoint("RIGHT", -82, 0)
    row.text:SetJustifyH("LEFT")
    row.value = NoWrap(row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    row.value:SetPoint("RIGHT", -6, 0)
    row.value:SetJustifyH("RIGHT")
    row.value:SetWidth(76)

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 0, -1)
    hl:SetPoint("BOTTOMRIGHT", 0, 1)
    hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.16)

    row:SetScript("OnClick", function(self)
        local e = self.item
        if not e then return end
        if e.header then
            ML:ToggleGroup(e.name)
        elseif IsModifiedClick and (IsModifiedClick("CHATLINK") or IsModifiedClick("DRESSUP")) then
            ML:LinkItem(e)
        else
            ML:SelectItem(e.key)
        end
    end)
    row:SetScript("OnEnter", function(self)
        local e = self.item
        if e and not e.header then AddItemTooltip(self, e) end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

function ML:FillItemRow(row, e)
    row.item = e
    local isHeader = e.header and true or false
    row.hbg:SetShown(isHeader)
    SetEdgesShown(row.hedges, isHeader)
    row.htext:SetShown(isHeader)
    row.htoggle:SetShown(isHeader)
    row.hcount:SetShown(isHeader)
    row.icon:SetShown(not isHeader)
    row.text:SetShown(not isHeader)
    row.value:SetShown(not isHeader)
    if isHeader then
        row.sel:Hide()
        row.selBar:Hide()
        row.htext:SetText(e.name)
        row.htoggle:SetText(e.collapsed and "+" or "–")
        row.hcount:SetText(ns.Commas(e.n))
        return
    end
    local selected = e.key == self.selectedKey
    row.sel:SetShown(selected)
    row.selBar:SetShown(selected)
    row.icon:SetTexture(e.icon or QUESTION)
    row.text:SetText(DisplayName(e))
    if e.label then
        SetColor(row.text, QualityRGB(e.quality))
    else
        SetColor(row.text, C.muted)
        if e.id and e.kind ~= "pet" then Ledger:QueueName(e.id, true) end
    end
    local sort = self.db.settings.sort
    if sort == "change" then
        row.value:SetText(Percent(e.change))
    elseif sort == "profit" then
        local p = e.profit
        if p and p > 0 then
            row.value:SetText("|cff40ff40+|r" .. ns.Money(p))
        elseif p then
            row.value:SetText(GREY .. (p < 0 and "-" or "") .. ns.PlainMoney(-p) .. "|r")
        elseif e.vendorPrice == 0 then
            row.value:SetText(GREY .. "no vendor|r")
        else
            row.value:SetText(GREY .. "—|r")
        end
    elseif sort == "deprofit" then
        local p, star = e.deProfit, e.dePartial and "*" or ""
        if p and p > 0 then
            row.value:SetText("|cff40ff40+|r" .. ns.Money(p) .. star)
        elseif p then
            row.value:SetText(GREY .. (p < 0 and "-" or "") .. ns.PlainMoney(-p) .. star .. "|r")
        elseif e.deState == "cannot" then
            row.value:SetText(GREY .. "can't DE|r")
        elseif e.deState == "noprice" then
            row.value:SetText(GREY .. "no prices|r")
        elseif e.deState == "nodata" then
            row.value:SetText(GREY .. "no data|r")
        else
            row.value:SetText(GREY .. "—|r")
        end
    elseif sort == "days" then
        row.value:SetText(Hex(C.text) .. ns.Commas(e.count) .. (e.count == 1 and " day" or " days") .. "|r")
    else
        row.value:SetText(ns.Money(e.m))
    end
end

-- Flat list of type headers + items for the virtual list
local DE_RANK = { ok = -1e15, noprice = -2e15, loading = -3e15, nodata = -4e15, cannot = -5e15, none = -math.huge }

local SORTS = {
    name   = function(a, b) if a.sn ~= b.sn then return a.sn < b.sn end return a.key < b.key end,
    price  = function(a, b) if a.m ~= b.m then return a.m > b.m end return a.sn < b.sn end,
    change = function(a, b)
        local x, y = a.change or -math.huge, b.change or -math.huge
        if x ~= y then return x > y end
        return a.sn < b.sn
    end,
    days   = function(a, b) if a.count ~= b.count then return a.count > b.count end return a.sn < b.sn end,
    -- most profit first; then items with no disenchant value yet; then gear with no data,
    -- gear that can't be disenchanted, and everything that isn't gear
    deprofit = function(a, b)
        local x, y = a.deProfit or DE_RANK[a.deState or "none"], b.deProfit or DE_RANK[b.deState or "none"]
        if x ~= y then return x > y end
        return a.sn < b.sn
    end,
    -- most profit first; then items with no vendor price known yet; then items vendors won't buy
    profit = function(a, b)
        local x = a.profit or ((a.vendorPrice == 0) and -math.huge or -1e15)
        local y = b.profit or ((b.vendorPrice == 0) and -math.huge or -1e15)
        if x ~= y then return x > y end
        return a.sn < b.sn
    end,
}

function ML:BuildEntries(realmKey, searchText)
    local idx = Ledger:GetIndex(realmKey)
    if not idx then return {}, 0 end
    local s = self.db.settings
    local terms = Ledger.ParseSearch(searchText)
    local searching = #terms > 0
    local useTips = s.searchTooltips
    self.searchActive = searching
    -- searches keep their own open/closed state: every search starts with all
    -- item types open, and closing one doesn't change the saved layout
    if not searching then wipe(self.searchCollapsed) end
    local recentFrom = ns.Today() - 7
    local priceMemo = {}
    local groups, total = {}, 0
    for _, e in pairs(idx.byKey) do
        total = total + 1
        local pass = true
        if s.recentOnly and (not e.last or e.last < recentFrom) then pass = false end
        if s.multiDay and (e.count or 0) < 2 then pass = false end
        if pass and searching then pass = Ledger:Matches(e, terms, useTips) end
        if pass then
            if s.sort == "profit" then e.profit, e.vendorPrice = Ledger:VendorProfit(e) end
            if s.sort == "deprofit" then
                e.deProfit, e.deValue, e.deState, e.dePartial = Ledger:DisenchantProfit(realmKey, e, priceMemo)
            end
            e.sn = e.lname or ("~" .. e.key)
            local gname = s.groupByType and (e.typeName or OTHER) or ""
            local g = groups[gname]
            if not g then g = {}; groups[gname] = g end
            g[#g + 1] = e
        end
    end
    local names = {}
    for gname in pairs(groups) do names[#names + 1] = gname end
    table.sort(names, function(a, b)
        if (a == OTHER) ~= (b == OTHER) then return b == OTHER end
        return a < b
    end)
    local cmp = SORTS[s.sort] or SORTS.name
    local entries = {}
    for _, gname in ipairs(names) do
        local list = groups[gname]
        local collapsed = s.groupByType and self:CollapseState()[gname] or false
        if s.groupByType then
            entries[#entries + 1] = { header = true, name = gname, n = #list, collapsed = collapsed }
        end
        if not collapsed then
            table.sort(list, cmp)
            for _, e in ipairs(list) do entries[#entries + 1] = e end
        end
    end
    return entries, total, idx.ready
end

ML.searchCollapsed = {}

-- The open/closed state in use: the search's own while searching, otherwise the saved one
function ML:CollapseState()
    return self.searchActive and self.searchCollapsed or self.db.collapsed
end

function ML:ToggleGroup(name)
    local state = self:CollapseState()
    state[name] = not state[name] or nil
    self:RefreshLedger()
end

function ML:SetAllCollapsed(collapse)
    local idx = Ledger:GetIndex(Ledger:ShownRealm())
    if not idx then return end
    local state = self:CollapseState()
    if not collapse then wipe(state) else
        for _, e in pairs(idx.byKey) do state[e.typeName or OTHER] = true end
    end
    self:RefreshLedger()
end

function ML:RefreshLedger(resetScroll)
    local f = self.frame
    if not f or not f.ledgerView:IsShown() then return end
    local lv = f.ledgerView
    local realmKey = Ledger:ShownRealm()
    if realmKey ~= self.listRealm then
        self.listRealm = realmKey
        self.selectedKey = nil
        resetScroll = true
    end
    if not self.selectedKey and self.db.settings.lastItem and realmKey then
        local realm = Ledger:Realm(realmKey)
        if realm and realm.items[self.db.settings.lastItem] then self.selectedKey = self.db.settings.lastItem end
    end
    local search = f.search:GetText() or ""
    local entries, total, ready = self:BuildEntries(realmKey, search)
    if ready then Ledger:EnsureTooltips(realmKey) end
    lv.itemList:SetData(entries, resetScroll or search ~= self.lastSearch)
    self.lastSearch = search

    local realm = realmKey and Ledger:Realm(realmKey)
    local empty
    if not realm or not next(realm.items) then
        if not Ledger:AuctionatorPresent() then
            empty = "Auctionator isn't loaded.\n\nMendeLedger records the prices Auctionator scans. Enable Auctionator, then scan the auction house."
        else
            empty = "Nothing recorded for this auction house yet.\n\nOpen the auction house and let Auctionator scan. MendeLedger records a few seconds after you close it, or press Record Now on the Options tab."
        end
    elseif not ready and #entries == 0 then
        empty = "Reading the ledger..."
    elseif #entries == 0 then
        if ns.Trim(search) ~= "" then
            local done, total = Ledger:TooltipProgress()
            if done and self.db.settings.searchTooltips then
                empty = ("No item matches \"%s\" yet.\n\nItem tooltips are still being read (%s of %s)."):format(
                    ns.Trim(search), ns.Commas(done), ns.Commas(total))
            else
                empty = ("No item matches \"%s\".\n\nNames appear once the game has loaded them; an item ID always works."):format(ns.Trim(search))
            end
        else
            empty = "No item passes the filters.\n\nCheck the Filter menu."
        end
    end
    lv.listEmpty:SetText(empty or "")
    lv.listEmpty:SetShown(empty ~= nil)
    self:UpdateRangeButtons()
    self:RefreshDetail()
end

function ML:SelectItem(key)
    self.selectedKey = key
    self.db.settings.lastItem = key
    self.frame.ledgerView.itemList:Render()
    self:RefreshDetail()
end

-------------------------------------------------------------------------------
-- Filter menu
-------------------------------------------------------------------------------
local FILTER_ITEMS = {
    { label = "Sort by" },
    { text = "Name", radio = "sort", value = "name" },
    { text = "Latest price", radio = "sort", value = "price" },
    { text = "7-day change", radio = "sort", value = "change" },
    { text = "Vendor profit", radio = "sort", value = "profit" },
    { text = "Disenchant profit", radio = "sort", value = "deprofit" },
    { text = "Days recorded", radio = "sort", value = "days" },
    { separator = true },
    { text = "Search item tooltips", setting = "searchTooltips" },
    { text = "Group by item type", setting = "groupByType" },
    { text = "Only items seen in the last 7 days", setting = "recentOnly" },
    { text = "Only items with 2 or more days", setting = "multiDay" },
    { separator = true },
    { text = "Graph: low–high band", setting = "showBand" },
    { text = "Graph: quantity bars", setting = "showQty" },
    { separator = true },
    { text = "Expand all item types", action = function() ML:SetAllCollapsed(false) end },
    { text = "Collapse all item types", action = function() ML:SetAllCollapsed(true) end },
}

function ML:CreateDropList()
    if self.dropList then return self.dropList end
    local l = CreateFrame("Frame", "MendeLedgerFilterMenu", UIParent)
    l:SetFrameStrata("FULLSCREEN_DIALOG")
    l:SetClampedToScreen(true)
    l:EnableMouse(true)
    l:Hide()
    local bg = l:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], 0.98)
    AddBorder(l, "BORDER", C.outline, 1, 2, -2)
    AddBorder(l, "BORDER", C.gold, 1, 1, 0)

    -- clicking anywhere else closes the menu
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:Hide()
    catcher:SetScript("OnClick", function() l:Hide() end)
    l:SetScript("OnShow", function() catcher:Show() end)
    l:SetScript("OnHide", function() catcher:Hide() end)
    tinsert(UISpecialFrames, "MendeLedgerFilterMenu")

    l.items = {}
    local y, w = -6, 250
    for _, item in ipairs(FILTER_ITEMS) do
        if item.separator then
            local sep = l:CreateTexture(nil, "ARTWORK")
            sep:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.55)
            sep:SetHeight(1)
            sep:SetPoint("TOPLEFT", 8, y - 4)
            sep:SetPoint("TOPRIGHT", -8, y - 4)
            y = y - 9
        elseif item.label then
            local fs = AddLabel(l, item.label, "GameFontNormalSmall", C.header)
            fs:SetPoint("TOPLEFT", 10, y - 4)
            y = y - 18
        else
            local b = CreateFrame("Button", nil, l)
            b:SetSize(w - 8, 20)
            b:SetPoint("TOPLEFT", 4, y)
            local hl = b:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.22)
            b.check = b:CreateTexture(nil, "OVERLAY")
            b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
            b.check:SetSize(16, 16)
            b.check:SetPoint("LEFT", 4, 0)
            b.box = b:CreateTexture(nil, "ARTWORK")
            b.box:SetSize(12, 12)
            b.box:SetPoint("CENTER", b.check, "CENTER", 0, 0)
            b.box:SetColorTexture(C.field[1], C.field[2], C.field[3], 1)
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.text:SetPoint("LEFT", 24, 0)
            b.text:SetText(item.text)
            SetColor(b.text, C.text)
            b.item = item
            b:SetScript("OnClick", function(self)
                local it, s = self.item, ML.db.settings
                if it.radio then
                    s[it.radio] = it.value
                elseif it.setting then
                    s[it.setting] = not s[it.setting]
                else
                    l:Hide()
                    it.action()
                    return
                end
                ML:UpdateDropList()
                ML:RefreshLedger()
            end)
            l.items[#l.items + 1] = b
            y = y - 20
        end
    end
    l:SetSize(w, -y + 6)
    self.dropList = l
    return l
end

function ML:UpdateDropList()
    local l = self.dropList
    if not l then return end
    local s = self.db.settings
    for _, b in ipairs(l.items) do
        local it = b.item
        if it.radio then
            b.box:Show()
            b.check:SetShown(s[it.radio] == it.value)
        elseif it.setting then
            b.box:Show()
            b.check:SetShown(s[it.setting] and true or false)
        else
            b.box:Hide()
            b.check:Hide()
        end
    end
end

function ML:ToggleFilterMenu(anchor)
    local l = self:CreateDropList()
    if l:IsShown() then l:Hide() return end
    l:ClearAllPoints()
    l:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    self:UpdateDropList()
    l:Show()
    l:Raise()
end

-------------------------------------------------------------------------------
-- Graph: lowest-buyout line, low-high band, quantity bars, one hover strip
-- per column. Two kinds of series share it:
--   day   one record per day from the daily ledger (positions in days)
--   scan  one record per Auctionator scan (positions in seconds), used for
--         ranges up to 7 days when the item has scan detail there
-- Columns: more records than MAX_COLS are grouped, a column then shows the
-- lowest and highest of its records. In scan view, a full scan that did not
-- list the item (sold out) breaks the line.
-------------------------------------------------------------------------------
local function Pooled(pool, i, make)
    local obj = pool[i]
    if not obj then obj = make(); pool[i] = obj end
    obj:Show()
    return obj
end

local function HideFrom(pool, i)
    for k = i, #pool do pool[k]:Hide() end
end

local function NiceStep(rough)
    if rough <= 0 then return 1 end
    local exp = 10 ^ math.floor(math.log10(rough))
    local f = rough / exp
    local nf = (f <= 1 and 1) or (f <= 2 and 2) or (f <= 5 and 5) or 10
    return math.max(1, nf * exp)
end

local function NiceScale(lo, hi, ticks)
    if hi <= lo then
        local pad = math.max(1, lo * 0.1)
        lo, hi = math.max(0, lo - pad), hi + pad
    end
    local pad = (hi - lo) * 0.08
    lo, hi = math.max(0, lo - pad), hi + pad
    local step = NiceStep((hi - lo) / ticks)
    return math.floor(lo / step) * step, math.ceil(hi / step) * step, step
end

local function DateOf(t)                  -- "Nov 16"
    return ("%s %d"):format(date("%b", t), tonumber(date("%d", t)))
end

local function DateTimeOf(t)              -- "Nov 16 2:30 PM"
    return DateOf(t) .. " " .. ns.TimeLabel(t)
end

local RANGE_NAMES = { [1] = "Last 24 hours", [3] = "Last 3 days" }

-- The series the graph, summary and records show for an item and the chosen range
function ML:BuildSeries(realmKey, e)
    local s = self.db.settings
    local range = s.range
    local L, bad = Ledger:History(realmKey, e.key)
    local S = { n = 0, t = {}, lo = {}, hi = {}, q = {}, bad = bad or 0 }
    local function Add(t, lo, hi, q)
        local n = S.n + 1
        S.n = n
        S.t[n], S.lo[n], S.hi[n], S.q[n] = t, lo, hi, q
    end

    if range > 0 and range <= 7 then
        S.short = true
        local sc = Ledger:ScanHistory(realmKey, e.key)
        local toT = time()
        local fromT = toT - range * 86400
        local inRange = 0
        if sc then
            for i = sc.n, 1, -1 do
                if sc.t[i] < fromT then break end
                inRange = inRange + 1
            end
        end
        S.scansInRange = inRange
        if s.useScans and inRange >= 1 and (inRange >= 2 or range == 1) then
            S.mode, S.from, S.to, S.bad = "scan", fromT, toT, sc.bad
            for i = 1, sc.n do
                if sc.t[i] >= fromT then Add(sc.t[i], sc.lo[i], sc.lo[i], sc.q[i]) end
            end
            S.breaks, S.fulls = Ledger:MissedScans(realmKey, sc, fromT, toT)
            return S
        end
    end

    S.mode = "day"
    if not L or L.n == 0 then return S end
    local toD = math.max(ns.Today(), L.d[L.n])
    S.from, S.to = (range > 0) and (toD - range + 1) or L.d[1], toD
    for i = 1, L.n do
        if L.d[i] >= S.from and L.d[i] <= S.to then Add(L.d[i], L.l[i], L.h[i], L.q[i]) end
    end
    S.lastDay = L.d[L.n]
    return S
end

function ML:CreateGraph(d)
    local g = CreateFrame("Frame", nil, d)
    g:SetSize(GW, GH)
    g:SetPoint("TOPLEFT", 12, -12)
    d.graph = g

    local plot = CreateFrame("Frame", nil, g)
    plot:SetPoint("BOTTOMLEFT", PL, PB)
    plot:SetSize(PW, PH)
    g.plot = plot
    g.canLine = plot.CreateLine ~= nil                                 -- RETEST

    local yAxis = plot:CreateTexture(nil, "BORDER")
    yAxis:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 0.9)
    yAxis:SetPoint("TOPLEFT")
    yAxis:SetPoint("BOTTOMLEFT")
    yAxis:SetWidth(1)
    local xAxis = plot:CreateTexture(nil, "BORDER")
    xAxis:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 0.9)
    xAxis:SetPoint("BOTTOMLEFT")
    xAxis:SetPoint("BOTTOMRIGHT")
    xAxis:SetHeight(1)

    g.grid, g.ylabels, g.xlabels, g.bands, g.qbars, g.lines, g.dots, g.hits = {}, {}, {}, {}, {}, {}, {}, {}

    g.guide = plot:CreateTexture(nil, "OVERLAY")
    g.guide:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.6)
    g.guide:SetWidth(1)
    g.guide:Hide()
    g.marker = plot:CreateTexture(nil, "OVERLAY", nil, 2)
    g.marker:SetColorTexture(1, 0.95, 0.8, 1)
    g.marker:SetSize(6, 6)
    g.marker:Hide()

    g.empty = AddLabel(g, "", "GameFontNormal", C.muted)
    g.empty:SetPoint("CENTER", plot, "CENTER", 0, 0)
    g.empty:SetWidth(PW - 40)
    g.empty:SetJustifyH("CENTER")
    if g.empty.SetSpacing then g.empty:SetSpacing(3) end

    -- legend under the graph, with the scans / days switch on the right
    local lg = CreateFrame("Frame", nil, d)
    lg:SetSize(GW, 16)
    lg:SetPoint("TOPLEFT", 12, -12 - GH - 3)
    local x = PL
    local function Swatch(kind, rgb, alpha, text)
        local t = lg:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(rgb[1], rgb[2], rgb[3], alpha)
        if kind == "line" then t:SetSize(14, 2) else t:SetSize(10, 10) end
        t:SetPoint("LEFT", x, 0)
        local fs = AddLabel(lg, text, "GameFontNormalSmall", C.muted)
        fs:SetPoint("LEFT", t, "RIGHT", 5, 0)
        x = x + (kind == "line" and 14 or 10) + 5 + fs:GetStringWidth() + 14
    end
    Swatch("line", C.header, 1, "Lowest buyout")
    Swatch("box", C.goldLight, 0.45, "Low–high")
    Swatch("box", C.stripe, 0.9, "Quantity")

    local view = FlatButton(lg, "", 112, 16)
    view:SetPoint("RIGHT", 0, 0)
    view:SetScript("OnClick", function()
        ML.db.settings.useScans = not ML.db.settings.useScans
        ML:RefreshDetail()
    end)
    view:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Scan view or daily view", 1, 0.82, 0)
        GameTooltip:AddLine("For ranges up to 7 days the graph can show every Auctionator scan instead of one point per day. Scan detail is kept for "
            .. ML.db.settings.keepScanDays .. " days (Options tab).", 1, 1, 1, true)
        if self.note then GameTooltip:AddLine(self.note, C.muted[1], C.muted[2], C.muted[3], true) end
        GameTooltip:Show()
    end)
    view:SetScript("OnLeave", function() GameTooltip:Hide() end)
    g.viewButton = view
end

function ML:UpdateViewButton(S)
    local b = self.frame.ledgerView.detail.graph.viewButton
    if not S or not S.short then b:Hide() return end
    b:Show()
    local scans = S.scansInRange or 0
    if S.mode == "scan" then
        b.label:SetText("View: each scan")
        b.note = nil
    elseif scans > 0 then
        b.label:SetText("View: daily")
        b.note = ("%d scan%s of this item in this range; click to see %s."):format(scans, scans == 1 and "" or "s", scans == 1 and "it" or "them")
    else
        b.label:SetText(GREY .. "View: daily|r")
        b.note = "No scans of this item in this range yet. Scan detail comes from Auctionator scans made while MendeLedger is running."
    end
    SetFlatSelected(b, S.mode == "scan")
end

function ML:DrawGraph(S, e)
    local g = self.frame.ledgerView.detail.graph
    local plot = g.plot
    local s = self.db.settings
    g.guide:Hide()
    g.marker:Hide()
    g.cols, g.mode = nil, S and S.mode or nil
    local used = { grid = 1, ylabels = 1, xlabels = 1, bands = 1, qbars = 1, lines = 1, dots = 1, hits = 1 }
    local function Finish(emptyText)
        for name, i in pairs(used) do HideFrom(g[name], i) end
        g.empty:SetText(emptyText or "")
        g.empty:SetShown(emptyText ~= nil)
    end

    if not e then return Finish("Pick an item on the left to see its price history.") end
    if not S or S.n == 0 then
        if S and S.mode == "day" and S.lastDay then
            return Finish(("No scans of this item in the %s.\nIt was last seen on %s."):format(
                RANGE_NAMES[s.range] and RANGE_NAMES[s.range]:lower() or ("last %d days"):format(s.range), ns.DayDate(S.lastDay)))
        end
        return Finish("No readable records for this item.")
    end

    local isScan = S.mode == "scan"
    local off = isScan and 0 or 0.5
    local span = isScan and math.max(1, S.to - S.from) or (S.to - S.from + 1)
    local bucket = math.max(1, math.ceil(span / MAX_COLS))

    local cols, byB = {}, {}
    for i = 1, S.n do
        local t = S.t[i]
        local b = math.floor((t - S.from) / bucket)
        local col = byB[b]
        if not col then
            col = { b = b, lo = S.lo[i], hi = S.hi[i], q = S.q[i], n = 0, t1 = t, t2 = t }
            byB[b] = col
            cols[#cols + 1] = col
        end
        col.n = col.n + 1
        if S.lo[i] < col.lo then col.lo = S.lo[i] end
        if S.hi[i] > col.hi then col.hi = S.hi[i] end
        if S.q[i] > col.q then col.q = S.q[i] end
        if t > col.t2 then col.t2 = t end
    end

    -- scales
    local minV, maxV, maxQ = math.huge, 0, 0
    for _, col in ipairs(cols) do
        if col.lo < minV then minV = col.lo end
        local top = s.showBand and col.hi or col.lo
        if top > maxV then maxV = top end
        if col.q > maxQ then maxQ = col.q end
    end
    local yMin, yMax, step = NiceScale(minV, maxV, 4)
    local function Y(v) return (v - yMin) / (yMax - yMin) * PH end
    for _, col in ipairs(cols) do
        col.x = math.max(0, math.min(PW - 1, PW * ((col.t1 + col.t2) / 2 - S.from + off) / span))
        col.y = Y(col.lo)
    end
    local slots = isScan and #cols or (span / bucket)
    local barW = math.max(2, math.min(14, 0.6 * PW / math.max(1, slots)))

    -- grid and price labels
    local v = yMin
    while v <= yMax + 0.5 do
        local y = Y(v)
        local line = Pooled(g.grid, used.grid, function()
            local t = plot:CreateTexture(nil, "BORDER")
            t:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 0.3)
            t:SetHeight(1)
            return t
        end)
        used.grid = used.grid + 1
        line:ClearAllPoints()
        line:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y)
        line:SetPoint("BOTTOMRIGHT", plot, "BOTTOMLEFT", PW, y)
        local label = Pooled(g.ylabels, used.ylabels, function()
            local fs = AddLabel(g, "", "GameFontNormalSmall", C.muted)
            fs:SetJustifyH("RIGHT")
            fs:SetWidth(PL - 8)
            return fs
        end)
        used.ylabels = used.ylabels + 1
        label:ClearAllPoints()
        label:SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, y)
        label:SetText(ns.AxisMoney(v))
        v = v + step
    end

    -- time labels
    local function XLabel(text, x)
        local fs = Pooled(g.xlabels, used.xlabels, function()
            local f = AddLabel(g, "", "GameFontNormalSmall", C.muted)
            f:SetJustifyH("CENTER")
            return f
        end)
        used.xlabels = used.xlabels + 1
        fs:ClearAllPoints()
        fs:SetPoint("TOP", plot, "BOTTOMLEFT", x, -5)
        fs:SetText(text)
    end
    if isScan then
        local short = span <= 36 * 3600
        for k = 0, 4 do
            local t = S.from + span * (0.06 + 0.88 * k / 4)
            XLabel(short and ns.TimeLabel(t) or ns.WhenLabel(t), PW * (t - S.from) / span)
        end
    else
        local ticks = math.min(5, span)
        local lastDay
        for k = 0, ticks - 1 do
            local day = S.from + math.floor(k * (span - 1) / math.max(1, ticks - 1) + 0.5)
            if day ~= lastDay then
                lastDay = day
                XLabel(ns.DayLabel(day), PW * ((day - S.from) + 0.5) / span)
            end
        end
    end

    -- quantity bars (bottom quarter, own scale)
    if s.showQty and maxQ > 0 then
        local qh = PH * 0.24
        for _, col in ipairs(cols) do
            if col.q > 0 then
                local bar = Pooled(g.qbars, used.qbars, function()
                    local t = plot:CreateTexture(nil, "ARTWORK", nil, -2)
                    t:SetColorTexture(C.stripe[1], C.stripe[2], C.stripe[3], 0.9)
                    return t
                end)
                used.qbars = used.qbars + 1
                bar:ClearAllPoints()
                bar:SetSize(barW, math.max(1, col.q / maxQ * qh))
                bar:SetPoint("BOTTOM", plot, "BOTTOMLEFT", col.x, 1)
            end
        end
    end

    -- low-high band (a day's range, or the range across a column's scans)
    if s.showBand then
        for _, col in ipairs(cols) do
            if col.hi > col.lo or not isScan then
                local band = Pooled(g.bands, used.bands, function()
                    local t = plot:CreateTexture(nil, "ARTWORK", nil, 0)
                    t:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.32)
                    return t
                end)
                used.bands = used.bands + 1
                local y1, y2 = Y(col.lo), Y(col.hi)
                band:ClearAllPoints()
                band:SetSize(barW, math.max(2, y2 - y1))
                band:SetPoint("BOTTOM", plot, "BOTTOMLEFT", col.x, y1)
            end
        end
    end

    -- lowest-buyout line and points; in scan view a missed full scan breaks it
    local breaks, bi = S.breaks or {}, 1
    for i, col in ipairs(cols) do
        if i > 1 and g.canLine then
            local prev = cols[i - 1]
            while breaks[bi] and breaks[bi] <= prev.t2 do bi = bi + 1 end
            local broken = breaks[bi] ~= nil and breaks[bi] < col.t1
            if not broken then
                local line = Pooled(g.lines, used.lines, function()
                    local l = plot:CreateLine(nil, "ARTWORK", nil, 3)
                    l:SetThickness(2)
                    l:SetColorTexture(C.header[1], C.header[2], C.header[3], 1)
                    return l
                end)
                used.lines = used.lines + 1
                line:SetStartPoint("BOTTOMLEFT", plot, prev.x, prev.y)
                line:SetEndPoint("BOTTOMLEFT", plot, col.x, col.y)
            end
        end
        if #cols <= 60 or not g.canLine then
            local dot = Pooled(g.dots, used.dots, function()
                local t = plot:CreateTexture(nil, "OVERLAY")
                t:SetColorTexture(C.header[1], C.header[2], C.header[3], 1)
                t:SetSize(4, 4)
                return t
            end)
            used.dots = used.dots + 1
            dot:ClearAllPoints()
            dot:SetPoint("CENTER", plot, "BOTTOMLEFT", col.x, col.y)
        end
    end

    -- hover strips: each column owns the space halfway to its neighbours (no polling)
    g.cols, g.bucket, g.mode = cols, bucket, S.mode
    for i, col in ipairs(cols) do
        local left = (i > 1) and (cols[i - 1].x + col.x) / 2 or 0
        local right = (i < #cols) and (col.x + cols[i + 1].x) / 2 or PW
        local hit = Pooled(g.hits, used.hits, function()
            local b = CreateFrame("Button", nil, plot)
            b:SetScript("OnEnter", function(self) ML:GraphHover(self) end)
            b:SetScript("OnLeave", function()
                g.guide:Hide(); g.marker:Hide(); GameTooltip:Hide()
            end)
            return b
        end)
        used.hits = used.hits + 1
        hit.col = col
        hit:ClearAllPoints()
        hit:SetSize(math.max(2, right - left), PH)
        hit:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", left, 0)
    end
    Finish(nil)
end

function ML:GraphHover(hit)
    local g = self.frame.ledgerView.detail.graph
    local col = hit.col
    if not col or not g.cols or not col.x then return end
    g.guide:ClearAllPoints()
    g.guide:SetPoint("BOTTOM", g.plot, "BOTTOMLEFT", col.x, 0)
    g.guide:SetHeight(PH)
    g.guide:Show()
    g.marker:ClearAllPoints()
    g.marker:SetPoint("CENTER", g.plot, "BOTTOMLEFT", col.x, col.y)
    g.marker:Show()

    local m = C.muted
    GameTooltip:SetOwner(hit, "ANCHOR_RIGHT")
    if g.mode == "scan" then
        if col.n == 1 then
            GameTooltip:AddLine(("%s, %s"):format(date("%A", col.t1), DateTimeOf(col.t1)), 1, 0.82, 0)
            GameTooltip:AddDoubleLine("Lowest buyout", ns.Coins(col.lo), m[1], m[2], m[3], 1, 1, 1)
            GameTooltip:AddDoubleLine("On sale", col.q > 0 and ns.Commas(col.q) or "unknown", m[1], m[2], m[3], 1, 1, 1)
        else
            local sameDay = date("%Y%m%d", col.t1) == date("%Y%m%d", col.t2)
            GameTooltip:AddLine(("%s – %s"):format(DateTimeOf(col.t1), sameDay and ns.TimeLabel(col.t2) or DateTimeOf(col.t2)), 1, 0.82, 0)
            GameTooltip:AddDoubleLine("Lowest buyout", ns.Coins(col.lo), m[1], m[2], m[3], 1, 1, 1)
            GameTooltip:AddDoubleLine("Highest of the scans", ns.Coins(col.hi), m[1], m[2], m[3], 1, 1, 1)
            GameTooltip:AddDoubleLine("Most on sale", col.q > 0 and ns.Commas(col.q) or "unknown", m[1], m[2], m[3], 1, 1, 1)
            GameTooltip:AddLine(("%d scans in this column"):format(col.n), m[1], m[2], m[3])
        end
    else
        if col.t1 == col.t2 then
            local t = ns.DayTime(col.t1)
            GameTooltip:AddLine(("%s, %s"):format(date("%A", t), ns.DayDate(col.t1)), 1, 0.82, 0)
        else
            GameTooltip:AddLine(("%s – %s"):format(ns.DayLabel(col.t1), ns.DayDate(col.t2)), 1, 0.82, 0)
        end
        GameTooltip:AddDoubleLine("Low", ns.Coins(col.lo), m[1], m[2], m[3], 1, 1, 1)
        GameTooltip:AddDoubleLine("High", ns.Coins(col.hi), m[1], m[2], m[3], 1, 1, 1)
        GameTooltip:AddDoubleLine("Quantity (most seen)", col.q > 0 and ns.Commas(col.q) or "unknown", m[1], m[2], m[3], 1, 1, 1)
        if g.bucket > 1 then
            GameTooltip:AddLine(("%d recorded day%s in this %d-day span"):format(col.n, col.n == 1 and "" or "s", g.bucket), m[1], m[2], m[3])
        end
    end
    GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- Summary and records (daily records, or every scan in scan view)
-------------------------------------------------------------------------------
local SUMMARY = { "price", "change", "low", "high", "avg", "qty", "count", "latest" }
local SUMMARY_LABELS = {
    day  = { price = "Latest price", change = "Change", low = "Lowest", high = "Highest",
             avg = "Average low", qty = "Average quantity", count = "Days recorded", latest = "Latest record" },
    scan = { price = "Latest scan", change = "Change", low = "Lowest", high = "Highest",
             avg = "Average", qty = "Average on sale", count = "Full scans", latest = "Last scanned" },
}
local HEADINGS = {
    day  = { "Date", "Low", "High", "Quantity", "Daily Records" },
    scan = { "Time", "Lowest buyout", "vs. previous", "On sale", "Scans" },
}

function ML:CreateSummary(d)
    local y0 = -12 - GH - 26
    AddSection(d, "Summary", y0, 12, -12)
    d.sum, d.sumLabel = {}, {}
    local colW = math.floor((DW - 24) / 2)
    for i, key in ipairs(SUMMARY) do
        local col, rowN = (i - 1) % 2, math.floor((i - 1) / 2)
        local x, y = 14 + col * colW, y0 - 24 - rowN * 16
        local label = AddLabel(d, SUMMARY_LABELS.day[key], "GameFontNormalSmall", C.muted)
        label:SetPoint("TOPLEFT", x, y)
        local value = NoWrap(AddLabel(d, "", "GameFontHighlightSmall", C.text))
        value:SetPoint("TOPLEFT", x + 96, y)
        value:SetWidth(colW - 100)
        d.sum[key], d.sumLabel[key] = value, label
    end

    local y1 = y0 - 24 - 4 * 16 - 10
    d.recTitle = AddSection(d, "Daily Records", y1, 12, -12)
    d.heads = {}
    local xs = { 16, 122, 262 }
    for i = 1, 3 do
        local fs = AddLabel(d, "", "GameFontNormalSmall", C.muted)
        fs:SetPoint("TOPLEFT", xs[i], y1 - 22)
        d.heads[i] = fs
    end
    d.heads[4] = AddLabel(d, "", "GameFontNormalSmall", C.muted)
    d.heads[4]:SetPoint("TOPRIGHT", -44, y1 - 22)
    d.heads[4]:SetJustifyH("RIGHT")

    local listW = DW - 24 - 24
    local scroll, child = MakeScroll("MendeLedgerDayScroll", d, listW)
    scroll:SetPoint("TOPLEFT", 12, y1 - 38)
    scroll:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -36, 8)
    d.dayList = AttachVirtualList(scroll, child, DAY_ROW_H, function()
        local row = CreateFrame("Frame", nil, child)
        row:SetSize(listW, DAY_ROW_H)
        row.date = NoWrap(AddLabel(row, "", "GameFontHighlightSmall", C.text))
        row.date:SetPoint("LEFT", 4, 0)
        row.date:SetWidth(104)
        row.low = NoWrap(AddLabel(row, "", "GameFontHighlightSmall", C.text))
        row.low:SetPoint("LEFT", 110, 0)
        row.high = NoWrap(AddLabel(row, "", "GameFontHighlightSmall", C.text))
        row.high:SetPoint("LEFT", 250, 0)
        row.qty = NoWrap(AddLabel(row, "", "GameFontHighlightSmall", C.text))
        row.qty:SetPoint("RIGHT", -8, 0)
        row.qty:SetJustifyH("RIGHT")
        return row
    end, function(row, r, idx)
        StripeRow(row, idx)
        if r.kind == "missed" then
            row.date:SetText(GREY .. DateTimeOf(r.t) .. "|r")
            row.low:SetText(GREY .. "not on sale (full scan)|r")
            row.high:SetText("")
            row.qty:SetText(GREY .. "0|r")
        elseif r.kind == "scan" then
            row.date:SetText(DateTimeOf(r.t))
            row.low:SetText(ns.Coins(r.l))
            row.high:SetText(r.prev and Percent((r.l - r.prev) / r.prev) or (GREY .. "—|r"))
            row.qty:SetText(r.q > 0 and ns.Commas(r.q) or (GREY .. "—|r"))
        else
            local t = ns.DayTime(r.t)
            row.date:SetText(("%s  %s"):format(date("%a", t), ns.DayLabel(r.t)))
            row.low:SetText(ns.Coins(r.l))
            row.high:SetText(r.h > r.l and ns.Coins(r.h) or (GREY .. "same|r"))
            row.qty:SetText(r.q > 0 and ns.Commas(r.q) or (GREY .. "—|r"))
        end
    end)
    d.dayEmpty = AddLabel(d, "", "GameFontNormalSmall", C.muted)
    d.dayEmpty:SetPoint("TOPLEFT", 18, y1 - 44)
    self:SetRecordsMode(d, "day")
end

function ML:SetRecordsMode(d, mode)
    if d.recMode == mode then return end
    d.recMode = mode
    local h = HEADINGS[mode]
    for i = 1, 4 do d.heads[i]:SetText(h[i]) end
    d.recTitle:SetText(h[5])
    for _, key in ipairs(SUMMARY) do d.sumLabel[key]:SetText(SUMMARY_LABELS[mode][key]) end
end

local function Summarize(S)
    local st = { n = S.n, sumLo = 0, sumQ = 0, nQ = 0 }
    for i = 1, S.n do
        local lo, hi, q = S.lo[i], S.hi[i], S.q[i]
        if i == 1 then st.firstLo = lo end
        st.lastLo, st.lastT = lo, S.t[i]
        if not st.minLo or lo < st.minLo then st.minLo, st.minT = lo, S.t[i] end
        if not st.maxHi or hi > st.maxHi then st.maxHi, st.maxT = hi, S.t[i] end
        st.sumLo = st.sumLo + lo
        if q > 0 then st.sumQ, st.nQ = st.sumQ + q, st.nQ + 1 end
    end
    return st
end

function ML:RefreshDetail()
    local f = self.frame
    if not f or not f.ledgerView:IsShown() then return end
    local lv, d = f.ledgerView, f.ledgerView.detail
    local realmKey = Ledger:ShownRealm()
    local idx = realmKey and Ledger.index[realmKey]
    local e = idx and self.selectedKey and idx.byKey[self.selectedKey] or nil
    self.selectedEntry = e
    local S = e and self:BuildSeries(realmKey, e) or nil
    local mode = (S and S.mode == "scan") and "scan" or "day"
    self:SetRecordsMode(d, mode)

    -- header
    if e then
        lv.icon:SetTexture(e.icon or QUESTION)
        lv.title:SetText(DisplayName(e))
        SetColor(lv.title, e.label and QualityRGB(e.quality) or C.muted)
        local parts = {}
        if e.typeName then parts[#parts + 1] = e.typeName end
        if e.subName and e.subName ~= e.typeName then parts[#parts + 1] = e.subName end
        if e.kind == "gear" and e.ilvl then parts[#parts + 1] = "item level " .. tostring(e.ilvl) end
        parts[#parts + 1] = (e.kind == "pet" and "species " or "item ") .. tostring(e.id or e.key)
        lv.stats:SetText(table.concat(parts, "  •  "))
        local spanDays = (e.last and e.first) and (e.last - e.first + 1) or 1
        lv.bar:SetMinMaxValues(0, spanDays)
        lv.bar:SetValue(e.count or 0)
        local scans = Ledger:ScanHistory(realmKey, e.key)
        lv.barText:SetText(("Recorded on %s of %s day%s since %s%s%s"):format(ns.Commas(e.count), ns.Commas(spanDays),
            spanDays == 1 and "" or "s", ns.DayLabel(e.first),
            (scans and scans.n > 0) and ("  •  %s scan%s kept"):format(ns.Commas(scans.n), scans.n == 1 and "" or "s") or "",
            (S and S.bad > 0) and ("  —  %d blocks unreadable here"):format(S.bad) or ""))
    else
        lv.icon:SetTexture(LEDGER_ICON)
        lv.title:SetText("Auctionator Price History")
        SetColor(lv.title, C.header)
        lv.stats:SetText("")
        lv.bar:SetMinMaxValues(0, 1)
        lv.bar:SetValue(0)
        lv.barText:SetText("Select an item to see how its price has moved")
    end

    self:UpdateViewButton(e and S)
    self:DrawGraph(S, e)

    -- summary for the chosen range
    for _, key in ipairs(SUMMARY) do d.sum[key]:SetText(GREY .. "—|r") end
    local rows = {}
    if e and S and S.n > 0 then
        local st = Summarize(S)
        local isScan = mode == "scan"
        local function When(t) return isScan and ns.WhenLabel(t) or ns.DayLabel(t) end
        d.sum.price:SetText(ns.Coins(isScan and st.lastLo or e.m))
        d.sum.change:SetText(st.n > 1 and (Percent((st.lastLo - st.firstLo) / st.firstLo) .. GREY .. "  over the range|r")
            or (GREY .. (isScan and "needs 2 scans|r" or "needs 2 days|r")))
        d.sum.low:SetText(("%s  %s(%s)|r"):format(ns.Coins(st.minLo), GREY, When(st.minT)))
        d.sum.high:SetText(("%s  %s(%s)|r"):format(ns.Coins(st.maxHi), GREY, When(st.maxT)))
        d.sum.avg:SetText(ns.Coins(st.sumLo / st.n))
        d.sum.qty:SetText(st.nQ > 0 and ns.Commas(math.floor(st.sumQ / st.nQ + 0.5)) or (GREY .. "unknown|r"))
        if isScan then
            local missed = #(S.breaks or {})
            d.sum.count:SetText(S.fulls > 0 and ("listed in %d of %d"):format(S.fulls - missed, S.fulls) or (GREY .. "none in range|r"))
            d.sum.latest:SetText(ns.Ago(st.lastT))
            -- every scan, newest first, with the full scans the item missed
            local missedT, mi = S.breaks or {}, #(S.breaks or {})
            for i = S.n, 1, -1 do
                while mi >= 1 and missedT[mi] > S.t[i] do
                    rows[#rows + 1] = { kind = "missed", t = missedT[mi] }
                    mi = mi - 1
                end
                rows[#rows + 1] = { kind = "scan", t = S.t[i], l = S.lo[i], q = S.q[i], prev = S.lo[i - 1] }
            end
            for k = mi, 1, -1 do rows[#rows + 1] = { kind = "missed", t = missedT[k] } end
        else
            d.sum.count:SetText(("%s of %s"):format(ns.Commas(st.n), ns.Commas(S.to - S.from + 1)))
            local age = ns.Today() - e.last
            d.sum.latest:SetText(("%s  %s(%s)|r"):format(ns.DayLabel(e.last), GREY,
                age <= 0 and "today" or (age == 1 and "yesterday" or (age .. " days ago"))))
            for i = S.n, 1, -1 do
                rows[#rows + 1] = { kind = "day", t = S.t[i], l = S.lo[i], h = S.hi[i], q = S.q[i] }
            end
        end
    end
    d.dayList:SetData(rows, true)
    d.dayEmpty:SetText((e and #rows == 0) and "No records in this range." or "")
end

-------------------------------------------------------------------------------
-- Options view
-------------------------------------------------------------------------------
local OPT_LEFT_R, OPT_RIGHT_X = 430, 450
local KEEP = { { 0, "Forever" }, { 730, "2 years" }, { 365, "1 year" }, { 180, "180 days" }, { 90, "90 days" } }
local STORAGE = { "Auction house", "Items", "Daily prices", "Stored", "As Lua tables", "Sealed blocks", "Saved by compression", "Scan detail" }

function ML:CreateOptionsView(f)
    local ov = CreateFrame("Frame", nil, f)
    ov:SetAllPoints()
    ov:Hide()
    f.optionsView = ov
    local LEFT_RULE = -(W - OPT_LEFT_R)
    local LW = OPT_LEFT_R - 44
    local RW = W - 20 - OPT_RIGHT_X

    local divider = ov:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 0.7)
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", (OPT_LEFT_R + OPT_RIGHT_X) / 2, -46)
    divider:SetPoint("BOTTOMLEFT", (OPT_LEFT_R + OPT_RIGHT_X) / 2, 56)

    ---------------------------------------------------------------- Recording
    AddSection(ov, "Recording", -46, 20, LEFT_RULE)
    ov.intro = AddLabel(ov, "", nil, C.muted)
    ov.intro:SetPoint("TOPLEFT", 22, -68)
    ov.intro:SetWidth(LW)
    if ov.intro.SetSpacing then ov.intro:SetSpacing(2) end

    ov.autoCheck = MakeCheck(ov, 18, -100, "Record after auction house scans", "Record automatically",
        "A few seconds after you close the auction house (and after each scan while it stays open), MendeLedger copies Auctionator's newest daily prices into the ledger. It also records shortly after you log in.",
        function(on) ML.db.settings.autoRecord = on end)

    local record = MenuButton(ov, "Record Now", 120)
    record:SetPoint("TOPLEFT", 20, -128)
    record:SetScript("OnClick", function() Ledger:RecordNow("button", false); ML:UpdateRecordingStatus() end)
    AddHoverTip(record, "Record Now", "Copy Auctionator's prices for the auction house you use into the ledger right away.")
    local import = MenuButton(ov, "Import All", 130)
    import:SetPoint("TOPLEFT", 148, -128)
    import:SetScript("OnClick", function() Ledger:ImportAll() end)
    AddHoverTip(import, "Import All", "Record everything Auctionator has prices for, including what your other characters scanned. Safe to repeat: nothing is counted twice.")

    ov.status1 = NoWrap(AddLabel(ov, "", "GameFontNormalSmall", C.text))
    ov.status1:SetPoint("TOPLEFT", 22, -160)
    ov.status1:SetWidth(LW)
    ov.status2 = NoWrap(AddLabel(ov, "", "GameFontNormalSmall", C.muted))
    ov.status2:SetPoint("TOPLEFT", 22, -174)
    ov.status2:SetWidth(LW)

    ---------------------------------------------------------------- Scan Detail
    AddSection(ov, "Scan Detail", -196, 20, LEFT_RULE)
    ov.scanCheck = MakeCheck(ov, 18, -218, "Keep every Auctionator scan", "Scan detail",
        "Auctionator keeps one low, high and quantity per day. With this on, MendeLedger also keeps each scan's lowest buyout and the number on sale, with the time, so the 24H, 3D and 7D ranges can show how prices move during the day.",
        function(on) ML:SetRecordScans(on) end)
    local sdesc = AddLabel(ov, "Each scan's lowest buyout and number on sale, with the time. Old scan detail expires; daily prices stay.", nil, C.muted)
    sdesc:SetPoint("TOPLEFT", 46, -244)
    sdesc:SetWidth(OPT_LEFT_R - 66)
    if sdesc.SetSpacing then sdesc:SetSpacing(2) end
    local keepLabel = AddLabel(ov, "Keep for", "GameFontNormalSmall", C.muted)
    keepLabel:SetPoint("TOPLEFT", 22, -282)
    ov.scanKeepButtons = {}
    local sx = 80
    for _, days in ipairs({ 7, 14, 30 }) do
        local b = FlatButton(ov, days .. " days", 64, 20)
        b:SetPoint("TOPLEFT", sx, -278)
        sx = sx + 68
        b.days = days
        b:SetScript("OnClick", function(self) ML:SetKeepScanDays(self.days) end)
        AddHoverTip(b, ("Keep %d days of scan detail"):format(days), "Removed a sealed block (128 scans of an item) at a time, so a little more can remain.")
        ov.scanKeepButtons[#ov.scanKeepButtons + 1] = b
    end
    ov.scanStatus = NoWrap(AddLabel(ov, "", "GameFontNormalSmall", C.text))
    ov.scanStatus:SetPoint("TOPLEFT", 22, -306)
    ov.scanStatus:SetWidth(LW)

    ---------------------------------------------------------------- Compression
    AddSection(ov, "Compression", -330, 20, LEFT_RULE)
    ov.compressCheck = MakeCheck(ov, 18, -352, "Compress sealed history", "Compress sealed history",
        "Each item's history is packed at about 6 bytes per record. Every 128 records become a sealed block that is never rewritten, compressed only when that makes it at least 10% smaller. Turning this off unpacks them again.",
        function(on) ML:SetCompress(on) end)
    ov.method = NoWrap(AddLabel(ov, "", "GameFontNormalSmall", C.text))
    ov.method:SetPoint("TOPLEFT", 22, -380)
    ov.method:SetWidth(LW - 104)
    local repack = FlatButton(ov, "Repack Now", 96, 20)
    repack:SetPoint("TOPLEFT", OPT_LEFT_R - 22 - 96, -376)
    repack:SetScript("OnClick", function() Ledger:Repack(false) end)
    AddHoverTip(repack, "Repack Now", "Re-store every sealed block to match the setting above. Only needed after changing it; it runs in the background.")

    ---------------------------------------------------------------- Keep History
    AddSection(ov, "Keep Daily History", -408, 20, LEFT_RULE)
    ov.keepButtons = {}
    local kx = 22
    for _, k in ipairs(KEEP) do
        local b = FlatButton(ov, k[2], k[1] == 0 and 66 or 72, 20)
        b:SetPoint("TOPLEFT", kx, -432)
        kx = kx + (k[1] == 0 and 66 or 72) + 4
        b.days = k[1]
        b:SetScript("OnClick", function(self) ML:SetKeepDays(self.days) end)
        AddHoverTip(b, k[1] == 0 and "Keep all daily prices" or ("Keep %s of daily prices"):format(k[2]),
            "Older daily prices are removed after the next recording, a sealed block at a time, so up to 128 extra days can remain.")
        ov.keepButtons[#ov.keepButtons + 1] = b
    end

    ---------------------------------------------------------------- Display
    AddSection(ov, "Display", -468, 20, LEFT_RULE)
    ov.minimapCheck = MakeCheck(ov, 18, -490, "Show minimap button", nil, nil,
        function(on) ML:SetMinimapButtonShown(on) end)
    ov.announceCheck = MakeCheck(ov, 18, -514, "Print a line in chat after each recording", "Recording messages",
        "When a recording adds daily prices, one line in chat says how many. Scans and recordings that find nothing new stay quiet.",
        function(on) ML.db.settings.announce = on end)

    ---------------------------------------------------------------- Storage
    AddSection(ov, "Storage", -46, OPT_RIGHT_X, -20)
    ov.storage = {}
    for i, name in ipairs(STORAGE) do
        local y = -70 - (i - 1) * 15
        local label = AddLabel(ov, name, "GameFontNormalSmall", C.muted)
        label:SetPoint("TOPLEFT", OPT_RIGHT_X + 2, y)
        local value = NoWrap(AddLabel(ov, "", "GameFontNormalSmall", C.text))
        value:SetPoint("TOPLEFT", OPT_RIGHT_X + 140, y)
        value:SetWidth(RW - 142)
        ov.storage[i] = value
    end

    ---------------------------------------------------------------- Realms
    AddSection(ov, "Auction Houses", -206, OPT_RIGHT_X, -20)
    local forget = FlatButton(ov, "Forget", 58, 18)
    forget:SetPoint("TOPRIGHT", -20, -202)
    forget:SetScript("OnClick", function() ML:ConfirmForget(Ledger:ShownRealm()) end)
    AddHoverTip(forget, "Forget", "Delete MendeLedger's history for the auction house (or old realm) being shown. Auctionator's own data is not touched.")
    local useHere = FlatButton(ov, "Use Here", 66, 18)
    useHere:SetPoint("TOPRIGHT", -84, -202)
    useHere:SetScript("OnClick", function()
        local key = Ledger:ShownRealm()
        if key then Ledger:SetCharacterRealm(key) end
    end)
    AddHoverTip(useHere, "This character uses this auction house",
        "Only needed if MendeLedger can't tell on its own (it reads your region, ruleset and faction). Records this character's prices into the entry being shown.")
    local rhint = AddLabel(ov, "Region / ruleset / faction. Click one to show it in the Ledger tab.", nil, C.muted)
    rhint:SetPoint("TOPLEFT", OPT_RIGHT_X + 2, -230)
    local rscroll, rchild = MakeScroll("MendeLedgerRealmScroll", ov, RW - 24)
    rscroll:SetPoint("TOPLEFT", OPT_RIGHT_X, -248)
    rscroll:SetPoint("BOTTOMRIGHT", ov, "TOPRIGHT", -44, -320)
    ov.realmList = AttachVirtualList(rscroll, rchild, 22, function()
        local row = CreateFrame("Button", nil, rchild)
        row:SetSize(RW - 24, 22)
        row.selBar = row:CreateTexture(nil, "ARTWORK")
        row.selBar:SetPoint("TOPLEFT")
        row.selBar:SetPoint("BOTTOMLEFT")
        row.selBar:SetWidth(2)
        row.selBar:SetColorTexture(1, 0.82, 0.2, 1)
        row.name = NoWrap(AddLabel(row, "", "GameFontHighlightSmall", C.text))
        row.name:SetPoint("LEFT", 8, 0)
        row.name:SetWidth(170)
        row.info = NoWrap(AddLabel(row, "", "GameFontNormalSmall", C.muted))
        row.info:SetPoint("RIGHT", -6, 0)
        row.info:SetJustifyH("RIGHT")
        row.info:SetWidth(RW - 24 - 190)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.16)
        row:SetScript("OnClick", function(self)
            if self.item then ML:ShowRealm(self.item.key); ML:SelectTab("ledger") end
        end)
        return row
    end, function(row, r, idx)
        row.item = r                                  -- the click handler needs to know the realm
        StripeRow(row, idx)
        row.selBar:SetShown(r.key == Ledger:ShownRealm())
        row.name:SetText(r.name)
        local mine = ML.charDB and (ML.charDB.ah == r.key or (not ML.charDB.ah and ML.charDB.realm == r.key))
        row.name:SetText(r.old and (r.name .. GREY .. "  (old realm)|r") or r.name)
        row.info:SetText(("%s%s items  •  %s"):format(mine and "|cffffd100this character|r  •  " or
            (r.merged and (GREY .. "history moved|r  •  ") or ""), ns.Commas(r.items), ns.Ago(r.lastRecord)))
    end)
    ov.realmEmpty = AddLabel(rchild, "", "GameFontNormalSmall", C.muted)
    ov.realmEmpty:SetPoint("TOPLEFT", 6, -6)
    ov.realmEmpty:SetWidth(RW - 40)

    ---------------------------------------------------------------- Client
    AddSection(ov, "Client", -336, OPT_RIGHT_X, -20)
    ov.probe = {}
    for i = 1, 16 do
        local b = CreateFrame("Button", nil, ov)
        b:SetSize(RW - 4, 14)
        b:SetPoint("TOPLEFT", OPT_RIGHT_X + 2, -360 - (i - 1) * 15)
        b.text = NoWrap(AddLabel(b, "", "GameFontNormalSmall", C.text))
        b.text:SetAllPoints()
        b:SetScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(self.entry.label, 1, 0.82, 0)
            GameTooltip:AddLine(self.entry.detail or "", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        ov.probe[i] = b
    end
end

function ML:UpdateRecordingStatus()
    local ov = self.frame and self.frame.optionsView
    if not ov then return end
    local scanJob = ns.FindJob("scan")
    if scanJob then
        local done, total = scanJob:Progress()
        ov.scanStatus:SetText(("Saving a scan: %s of %s items"):format(ns.Commas(done), ns.Commas(total)))
    elseif not self.db.settings.recordScans then
        ov.scanStatus:SetText(GREY .. "Off: only daily prices are kept.|r")
    elseif not Ledger.scanHook then
        ov.scanStatus:SetText(GREY .. "Waiting for Auctionator (it must be loaded).|r")
    else
        ov.scanStatus:SetText(Ledger.scanStatus or "No scan seen this session yet.")
    end
    local job = ns.FindJob("record")
    if job then
        local done, total = job:Progress()
        ov.status1:SetText(("%s: %s of %s items"):format(job.label, ns.Commas(done), ns.Commas(total)))
    else
        ov.status1:SetText(Ledger.status or "Nothing recorded yet this session.")
    end
    local key = Ledger:ShownRealm()
    local realm = key and Ledger:Realm(key)
    ov.status2:SetText(realm and ("Last recorded %s for %s"):format(ns.Ago(realm.lastRecord), Ledger:RealmName(key))
        or (Ledger:AuctionatorPresent() and "Nothing recorded yet." or "Auctionator isn't loaded."))
end

function ML:RefreshOptions()
    local f = self.frame
    if not f or not f.optionsView:IsShown() then return end
    local ov, s = f.optionsView, self.db.settings

    ov.intro:SetText(("Auctionator keeps its last %d days of prices. MendeLedger copies each day into its own ledger, which keeps growing."):format(Ledger:AuctionatorDays()))
    ov.autoCheck:SetChecked(s.autoRecord)
    ov.compressCheck:SetChecked(s.compress)
    ov.minimapCheck:SetChecked(not self.db.minimap.hide)
    ov.announceCheck:SetChecked(s.announce)
    ov.method:SetText(Ledger:CanCompress() and ("Method: " .. Ledger.compressMethod)
        or (GREY .. "Deflate isn't available on this client, so history is packed but not compressed.|r"))
    for _, b in ipairs(ov.keepButtons) do SetFlatSelected(b, b.days == s.keepDays) end
    ov.scanCheck:SetChecked(s.recordScans)
    for _, b in ipairs(ov.scanKeepButtons) do SetFlatSelected(b, b.days == s.keepScanDays) end
    self:UpdateRecordingStatus()

    -- storage
    local key = Ledger:ShownRealm()
    local realm = key and Ledger:Realm(key)
    local st = realm and realm.stats
    local vals = {}
    if st then
        vals[1] = Ledger:RealmName(key) .. (Ledger:RealmName(key) ~= key and (GREY .. "  (" .. key .. ")|r") or "")
        vals[2] = ns.Commas(st.items)
        vals[3] = st.first and ("%s  %s(%s – %s)|r"):format(ns.Commas(st.records), GREY, ns.DayLabel(st.first), ns.DayDate(st.last)) or ns.Commas(st.records)
        vals[4] = ("%s  %s(%.1f bytes per daily price)|r"):format(ns.Bytes(st.bytes), GREY, st.records > 0 and st.bytes / st.records or 0)
        local lua = st.records * 50
        vals[5] = ("about %s  %s(%.1fx larger)|r"):format(ns.Bytes(lua), GREY, st.bytes > 0 and lua / st.bytes or 0)
        vals[6] = ("%d compressed, %d stored as is"):format(st.compressed, st.rawSealed)
        vals[7] = ns.Bytes(math.max(0, st.unpacked - st.bytes))
    else
        vals[1] = key and Ledger:RealmName(key) or (GREY .. "none yet|r")
    end
    local ss = realm and realm.scanStats
    if ss and ss.scans > 0 then
        vals[8] = ("%s scan%s, %s  %s(%s saved)|r"):format(ns.Commas(ss.scans), ss.scans == 1 and "" or "s",
            ns.Bytes(ss.bytes), GREY, ns.Bytes(math.max(0, ss.unpacked - ss.bytes)))
    else
        vals[8] = GREY .. "no scans kept yet|r"
    end
    for i, fs in ipairs(ov.storage) do fs:SetText(vals[i] or (GREY .. "—|r")) end

    -- realms
    local list = Ledger:RealmList()
    ov.realmList:SetData(list)
    ov.realmEmpty:SetText(#list == 0 and "No auction houses recorded yet." or "")

    -- client check
    local probe = ns.Probe()
    for i, b in ipairs(ov.probe) do
        local r = probe[i]
        b.entry = r
        if r then
            b.text:SetText(("%s•|r %s  %s%s|r"):format(r.ok and "|cff40ff40" or "|cffff6040", r.label, Hex(C.muted), r.detail or ""))
            b:Show()
        else
            b:Hide()
        end
    end
end

function ML:SetCompress(on)
    self.db.settings.compress = on and true or false
    ns.Print("compression of sealed history is " .. (on and "on" or "off") .. "; repacking in the background.")
    Ledger:Repack(true)
    self:RequestUIRefresh()
end

function ML:SetRecordScans(on)
    self.db.settings.recordScans = on and true or false
    ns.Print(on and "keeping every Auctionator scan (prices by time of day)." or "scan detail off; scans already kept stay until they expire.")
    self:RequestUIRefresh()
end

function ML:SetKeepScanDays(days)
    self.db.settings.keepScanDays = days
    ns.Print(("keeping %d days of scan detail."):format(days))
    for key in pairs(self.db.realms) do Ledger:PruneScans(key, true) end
    self:RequestUIRefresh()
end

function ML:SetKeepDays(days)
    self.db.settings.keepDays = days
    if days == 0 then
        ns.Print("keeping all history.")
    else
        ns.Print(("keeping %d days of history; older prices are removed now and after each recording."):format(days))
        for key in pairs(self.db.realms) do Ledger:Prune(key) end
    end
    self:RequestUIRefresh()
end

function ML:ConfirmForget(key)
    if not key or not self.db.realms[key] then ns.Print("there is nothing recorded to forget.") return end
    StaticPopup_Show("MENDELEDGER_FORGET", Ledger:RealmName(key), nil, key)      -- RETEST
end

-------------------------------------------------------------------------------
-- Game Options -> AddOns entry, addon compartment, minimap button, chat links
-------------------------------------------------------------------------------
function ML:RegisterBlizzardOptions()
    local panel = CreateFrame("Frame")
    panel.name = "MendeLedger"
    local t = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 16, -16)
    t:SetText("MendeLedger")
    local d = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -10)
    d:SetWidth(520)
    d:SetJustifyH("LEFT")
    d:SetText("A GUI for seeing Auctionator price history. Recording, compression and storage settings are on the Options tab of the MendeLedger window. You can also open it with /mendel.")
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(220, 24)
    b:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 0, -14)
    b:SetText("Open MendeLedger")
    b:SetScript("OnClick", function()
        -- the Settings panel is protected UI: close it only out of combat
        ns.AfterCombat("closeSettings", function()
            if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end       -- RETEST
            if GameMenuFrame and GameMenuFrame:IsShown() then HideUIPanel(GameMenuFrame) end
        end)
        ML:Open("options")
    end)
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then   -- RETEST
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    end
end

local function AddShortcutTooltip(tooltip)
    tooltip:AddLine("MendeLedger", 1, 0.82, 0)
    tooltip:AddLine("|cffffd100Left-click|r  open MendeLedger  " .. GREY .. "(/mendel)|r", 1, 1, 1)
    tooltip:AddLine("|cffffd100Right-click|r  record Auctionator's prices now  " .. GREY .. "(/mendel record)|r", 1, 1, 1)
    local key = ML.db and Ledger:ShownRealm()
    local realm = key and Ledger:Realm(key)
    if realm then
        tooltip:AddLine(("%s: %s items, recorded %s"):format(Ledger:RealmName(key), ns.Commas(realm.stats and realm.stats.items or 0),
            ns.Ago(realm.lastRecord)), C.muted[1], C.muted[2], C.muted[3])
    end
end

local function ShortcutClick(button)
    if button == "RightButton" then Ledger:RecordNow("shortcut", false) else ML:Toggle() end
end

-- The addon compartment (button by the minimap) works like the minimap button
function MendeLedger_OnAddonCompartmentClick(_, mouseButton)
    if ML.db then ShortcutClick(mouseButton) end
end

function MendeLedger_OnAddonCompartmentEnter(_, button)
    local owner = button or UIParent
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    AddShortcutTooltip(GameTooltip)
    GameTooltip:Show()
end

function MendeLedger_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

-- Minimap button (LibDataBroker launcher drawn by LibDBIcon)
function ML:CreateMinimapButton()
    if self.minimapIcon then return end
    local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
    local DBIcon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)
    if not LDB or not DBIcon then return end
    local launcher = LDB:NewDataObject("MendeLedger", {
        type = "launcher",
        text = "MendeLedger",
        icon = LEDGER_ICON,
        OnClick = function(_, button) ShortcutClick(button) end,
        OnTooltipShow = function(tooltip) AddShortcutTooltip(tooltip) end,
    })
    if not launcher then return end
    DBIcon:Register("MendeLedger", launcher, self.db.minimap)        -- RETEST: LibDBIcon on Forever
    self.minimapIcon = DBIcon
end

function ML:SetMinimapButtonShown(shown)
    self.db.minimap.hide = not shown
    if self.minimapIcon then
        if shown then self.minimapIcon:Show("MendeLedger") else self.minimapIcon:Hide("MendeLedger") end
    end
    if self.frame and self.frame.optionsView:IsShown() then self.frame.optionsView.minimapCheck:SetChecked(shown) end
end

-- With the search box selected, shift-clicking an item searches for it
local function OnInsertLink(link)
    local f = ML.frame
    if not f or not f:IsShown() or not f.search:HasFocus() then return end
    link = ns.Text(link)
    local name = link and link:match("|h%[(.-)%]|h")
    if name then
        f.search:SetText(name)
        f.search:SetCursorPosition(#name)
    end
end

local function HookChatLinks()
    if ChatFrameUtil and type(ChatFrameUtil.InsertLink) == "function" then      -- RETEST
        hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink)
    elseif type(rawget(_G, "ChatEdit_InsertLink")) == "function" then
        hooksecurefunc("ChatEdit_InsertLink", OnInsertLink)
    end
end

function ML:InitUI(Step)
    Step = Step or function(_, fn) fn() end
    Step("confirmation dialog", function() StaticPopupDialogs["MENDELEDGER_FORGET"] = {
        text = "Forget all MendeLedger history for %s?\n\nAuctionator's own data is not touched.",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, data) Ledger:ForgetRealm(data) end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    } end)
    Step("Settings panel entry", function() self:RegisterBlizzardOptions() end)
    Step("minimap button", function() self:CreateMinimapButton() end)
    Step("chat link hook", HookChatLinks)
end
