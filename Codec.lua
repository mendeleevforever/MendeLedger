local addonName, ns = ...
-- Codec.lua
-- How MendeLedger stores price history. Plain Lua 5.1 with no game API calls,
-- so it can be tested outside the game (compression is plugged in by Ledger.lua).
--
-- One string per item, keyed like Auctionator ("2589", "g:12345:62", "p:40").
-- Every number is an unsigned LEB128 varint: 7 bits per byte, high bit = "more".
--
--   item    := FORMAT m ref7 nSeg segment*
--   segment := kind count firstDay span [rawLen] byteLen body
--   body    := ( dayDelta low highMinusLow quantity ) * count
--
--   FORMAT    one byte, currently \1
--   m         latest minimum buyout Auctionator saw, in copper
--   ref7      daily low of the newest record at least 7 days older than the
--             newest record (0 = none); drives the 7-day change in the list
--   kind      0 = body stored as is, 1 = body compressed (LibCompress stream)
--   span      lastDay - firstDay
--   rawLen    kind 1 only: body length before compression
--   dayDelta  days since the previous record (the first counts from firstDay)
--   low/high  lowest and highest minimum buyout seen that day (Auctionator's
--             "l" and "h"); quantity = most units seen that day ("a"), 0 = unknown
--
-- The last segment is the open tail. Once a tail holds SEAL records that are
-- all older than "today", the oldest SEAL of them become a sealed block that
-- normal recording never rewrites again. A sealed block is compressed only
-- when that makes it at least MIN_SAVING smaller ("compress if useful").
-- Measured on a live Forever realm: about 6 bytes per item per day before
-- compression, against about 50 bytes as a Lua table.

local Codec = {}
ns.Codec = Codec

local floor, char, byte, sub, concat = math.floor, string.char, string.byte, string.sub, table.concat
local unpack = unpack

Codec.FORMAT     = 1
Codec.SEAL       = 128
Codec.MIN_SAVING = 0.10
Codec.compress   = nil      -- function(rawString) -> compressedString or nil
Codec.decompress = nil      -- function(compressedString) -> rawString or nil

local FORMAT_BYTE = char(Codec.FORMAT)
local CHUNK = 4000          -- bytes per string.char(unpack(...)) call, well under the C stack limit
local MAX_MUL = 2 ^ 53

-------------------------------------------------------------------------------
-- Varints
-------------------------------------------------------------------------------
local function PushVarint(b, n)
    n = floor(n)
    if n < 0 then n = 0 end
    local count = #b
    while n >= 128 do
        local r = n % 128
        count = count + 1
        b[count] = r + 128
        n = (n - r) / 128
    end
    b[count + 1] = n
end

local function BytesToString(b)
    local n = #b
    if n <= CHUNK then return char(unpack(b)) end
    local parts = {}
    for i = 1, n, CHUNK do
        parts[#parts + 1] = char(unpack(b, i, math.min(i + CHUNK - 1, n)))
    end
    return concat(parts)
end

-- returns value, nextPos  (value nil when the string ends early or is corrupt)
local function ReadVarint(s, pos)
    local n, mul = 0, 1
    while true do
        local c = byte(s, pos)
        if not c then return nil, pos end
        pos = pos + 1
        if c < 128 then return n + c * mul, pos end
        n = n + (c - 128) * mul
        mul = mul * 128
        if mul > MAX_MUL then return nil, pos end
    end
end
Codec.ReadVarint = ReadVarint

-------------------------------------------------------------------------------
-- Record lists: parallel arrays, so a long history costs four tables, not one per day
-------------------------------------------------------------------------------
local function NewList()
    return { n = 0, d = {}, l = {}, h = {}, q = {} }
end
Codec.NewList = NewList

local function Push(L, d, lo, hi, q)
    local n = L.n + 1
    L.n = n
    L.d[n], L.l[n], L.h[n], L.q[n] = d, lo, hi, q
end
Codec.Push = Push

-- Union of two day-sorted lists. Same day: lowest low, highest high, most
-- units, which is how Auctionator itself combines scans within one day, so
-- merging is idempotent and the order of merges does not matter.
local function MergeLists(A, B)
    local C, added = NewList(), 0
    local i, j = 1, 1
    local an, bn = A.n, B.n
    while i <= an or j <= bn do
        if j > bn or (i <= an and A.d[i] < B.d[j]) then
            Push(C, A.d[i], A.l[i], A.h[i], A.q[i]); i = i + 1
        elseif i > an or B.d[j] < A.d[i] then
            Push(C, B.d[j], B.l[j], B.h[j], B.q[j]); added = added + 1; j = j + 1
        else
            local lo = A.l[i] < B.l[j] and A.l[i] or B.l[j]
            local hi = A.h[i] > B.h[j] and A.h[i] or B.h[j]
            local q  = A.q[i] > B.q[j] and A.q[i] or B.q[j]
            Push(C, A.d[i], lo, hi, q); i = i + 1; j = j + 1
        end
    end
    return C, added
end
Codec.MergeLists = MergeLists

-------------------------------------------------------------------------------
-- Parsing
-------------------------------------------------------------------------------
-- Returns { m, ref7, segs = { {kind, count, first, last, rawLen, bodyPos, bodyLen, hdrPos, endPos} } }
-- or nil when the string is not a MendeLedger item.
function Codec.Parse(s)
    if type(s) ~= "string" or sub(s, 1, 1) ~= FORMAT_BYTE then return nil end
    local pos = 2
    local m, ref7, nSeg
    m, pos = ReadVarint(s, pos);    if not m then return nil end
    ref7, pos = ReadVarint(s, pos); if not ref7 then return nil end
    nSeg, pos = ReadVarint(s, pos); if not nSeg then return nil end
    local item = { m = m, ref7 = ref7, segs = {}, s = s }
    for i = 1, nSeg do
        local hdrPos = pos
        local kind, count, first, span, rawLen, len
        kind, pos = ReadVarint(s, pos);  if not kind then return nil end
        count, pos = ReadVarint(s, pos); if not count then return nil end
        first, pos = ReadVarint(s, pos); if not first then return nil end
        span, pos = ReadVarint(s, pos);  if not span then return nil end
        if kind == 1 then rawLen, pos = ReadVarint(s, pos); if not rawLen then return nil end end
        len, pos = ReadVarint(s, pos);   if not len then return nil end
        if pos + len - 1 > #s then return nil end
        item.segs[i] = {
            kind = kind, count = count, first = first, last = first + span, rawLen = rawLen,
            bodyPos = pos, bodyLen = len, hdrPos = hdrPos, endPos = pos + len - 1,
        }
        pos = pos + len
    end
    return item
end

local function SegmentString(item, seg)
    return sub(item.s, seg.hdrPos, seg.endPos)
end

-- A sealed segment is any segment but an open tail (the last one with fewer than SEAL records)
local function IsTail(item, i)
    return i == #item.segs and item.segs[i].count < Codec.SEAL
end

-- Cheap header summary for the item list and storage statistics.
-- m, ref7, records, firstDay, lastDay, segments, compressedBlocks, rawSealedBlocks, unpackedBytes
function Codec.Summary(s)
    local item = Codec.Parse(s)
    if not item then return nil end
    local segs = item.segs
    local count, comp, rawSealed, unpacked = 0, 0, 0, #s
    for i, seg in ipairs(segs) do
        count = count + seg.count
        if seg.kind == 1 then
            comp = comp + 1
            unpacked = unpacked - seg.bodyLen + (seg.rawLen or seg.bodyLen)
        elseif not IsTail(item, i) then
            rawSealed = rawSealed + 1
        end
    end
    local first = segs[1] and segs[1].first or nil
    local last  = segs[#segs] and segs[#segs].last or nil
    return item.m, item.ref7, count, first, last, #segs, comp, rawSealed, unpacked
end

-------------------------------------------------------------------------------
-- Segment bodies
-------------------------------------------------------------------------------
local function DecodeBody(body, count, first, L, fromDay)
    local pos, prev = 1, first
    for _ = 1, count do
        local dd, lo, span, q
        dd, pos = ReadVarint(body, pos);   if not dd then return false end
        lo, pos = ReadVarint(body, pos);   if not lo then return false end
        span, pos = ReadVarint(body, pos); if not span then return false end
        q, pos = ReadVarint(body, pos);    if not q then return false end
        prev = prev + dd
        if not fromDay or prev >= fromDay then Push(L, prev, lo, lo + span, q) end
    end
    return true
end

local function SegmentBody(item, seg)
    local body = sub(item.s, seg.bodyPos, seg.endPos)
    if seg.kind == 0 then return body end
    if seg.kind == 1 and Codec.decompress then
        local raw = Codec.decompress(body)
        if type(raw) == "string" then return raw end
    end
    return nil
end

-- Appends a segment's records to L. False when the block can't be read
-- (corrupt, or compressed with a codec this client doesn't have).
local function DecodeSegment(item, seg, L, fromDay)
    local body = SegmentBody(item, seg)
    if not body then return false end
    return DecodeBody(body, seg.count, seg.first, L, fromDay)
end

local function EncodeBody(L, i1, i2)
    local b, prev = {}, L.d[i1]
    for i = i1, i2 do
        local lo, hi = L.l[i], L.h[i]
        if hi < lo then hi = lo end
        PushVarint(b, L.d[i] - prev)
        PushVarint(b, lo)
        PushVarint(b, hi - lo)
        PushVarint(b, L.q[i])
        prev = L.d[i]
    end
    return BytesToString(b)
end

local function SegmentFromBody(kind, count, first, last, raw, bytes)
    local b = {}
    PushVarint(b, kind)
    PushVarint(b, count)
    PushVarint(b, first)
    PushVarint(b, last - first)
    if kind == 1 then PushVarint(b, #raw) end
    PushVarint(b, #bytes)
    return BytesToString(b) .. bytes
end

-- Compress if useful: only when the result is at least MIN_SAVING smaller
local function MaybeCompress(raw)
    if not Codec.compress or not Codec.decompress or #raw < 64 then return nil end
    local ok, packed = pcall(Codec.compress, raw)
    if not ok or type(packed) ~= "string" then return nil end
    if #packed > #raw * (1 - Codec.MIN_SAVING) then return nil end
    local ok2, check = pcall(Codec.decompress, packed)        -- never store what can't be read back
    if not ok2 or check ~= raw then return nil end
    return packed
end

local function EncodeSegment(L, i1, i2, sealed, compress)
    local raw = EncodeBody(L, i1, i2)
    local count, first, last = i2 - i1 + 1, L.d[i1], L.d[i2]
    if sealed and compress then
        local packed = MaybeCompress(raw)
        if packed then return SegmentFromBody(1, count, first, last, raw, packed), true end
    end
    return SegmentFromBody(0, count, first, last, raw, raw), false
end

local function Assemble(m, ref7, parts)
    local b = {}
    PushVarint(b, m or 0)
    PushVarint(b, ref7 or 0)
    PushVarint(b, #parts)
    return FORMAT_BYTE .. BytesToString(b) .. concat(parts)
end

-------------------------------------------------------------------------------
-- Public operations
-------------------------------------------------------------------------------
-- Every record with day >= fromDay (all when nil). Returns list, unreadableBlocks.
function Codec.Decode(s, fromDay)
    local L = NewList()
    local item = Codec.Parse(s)
    if not item then return L, 0 end
    local bad = 0
    for _, seg in ipairs(item.segs) do
        if not fromDay or seg.last >= fromDay then
            if not DecodeSegment(item, seg, L, fromDay) then bad = bad + 1 end
        end
    end
    return L, bad
end

local function FindRef7(L, lastDay)
    local target = lastDay - 7
    for i = L.n, 1, -1 do
        if L.d[i] <= target then return L.l[i] end
    end
    return nil
end

-- Merges new day records P (sorted, unique days) into an item string.
--   m         latest minimum buyout (nil keeps the stored one)
--   compress  try to compress blocks that get sealed now
--   openFrom  records on or after this day stay in the open tail (today's
--             prices can still change), so sealed blocks are final
-- Returns newString, recordsAdded. newString == s when nothing changed.
function Codec.Merge(s, P, m, compress, openFrom)
    local item = s and Codec.Parse(s) or nil
    if not item then
        item = { m = 0, ref7 = 0, segs = {}, s = "" }
        if P.n == 0 then return s, 0 end
    end
    m = m or item.m
    local segs, nSeg = item.segs, #item.segs
    if P.n == 0 then
        if m == item.m then return s, 0 end
        local parts = {}
        for i = 1, nSeg do parts[i] = SegmentString(item, segs[i]) end
        return Assemble(m, item.ref7, parts), 0
    end

    -- first segment the new records can touch; normally the open tail
    local start = nSeg + 1
    for i = 1, nSeg do
        if segs[i].last >= P.d[1] then start = i; break end
    end
    if start > nSeg and nSeg > 0 and IsTail(item, nSeg) then start = nSeg end

    -- decode that range; a block that can't be read is kept untouched and
    -- only newer records are merged after it
    local E = NewList()
    local i = start
    while i <= nSeg do
        if DecodeSegment(item, segs[i], E) then
            i = i + 1
        else
            local keepThrough = segs[i].last
            local Q = NewList()
            for k = 1, P.n do
                if P.d[k] > keepThrough then Push(Q, P.d[k], P.l[k], P.h[k], P.q[k]) end
            end
            P = Q
            start, i, E = i + 1, i + 1, NewList()
        end
    end

    local C, added = MergeLists(E, P)
    if C.n == 0 then return s, 0 end

    local parts = {}
    for k = 1, start - 1 do parts[#parts + 1] = SegmentString(item, segs[k]) end
    local seal, k = Codec.SEAL, 1
    openFrom = openFrom or math.huge
    while C.n - k + 1 >= seal and C.d[k + seal - 1] < openFrom do
        parts[#parts + 1] = EncodeSegment(C, k, k + seal - 1, true, compress)
        k = k + seal
    end
    if k <= C.n then parts[#parts + 1] = EncodeSegment(C, k, C.n, false, false) end

    local ref7 = FindRef7(C, C.d[C.n])
    if not ref7 and start > 1 then
        local prevList = NewList()
        if DecodeSegment(item, segs[start - 1], prevList) then ref7 = FindRef7(prevList, C.d[C.n]) end
    end

    local out = Assemble(m, ref7 or 0, parts)
    if out == s then return s, 0 end
    return out, added
end

-- Drops history older than cutoffDay, a whole block at a time so sealed
-- blocks are not rewritten daily (a block straddling the cutoff stays until
-- all of it is older). The open tail is trimmed exactly.
-- Returns newString (nil when nothing is left), recordsRemoved.
function Codec.Prune(s, cutoffDay)
    local item = Codec.Parse(s)
    if not item then return s, 0 end
    local parts, removed = {}, 0
    for i, seg in ipairs(item.segs) do
        if seg.last < cutoffDay then
            removed = removed + seg.count
        elseif IsTail(item, i) and seg.first < cutoffDay then
            local L = NewList()
            local ok = DecodeSegment(item, seg, L, cutoffDay)
            if not ok then
                parts[#parts + 1] = SegmentString(item, seg)      -- unreadable: leave it alone
            elseif L.n > 0 then
                removed = removed + seg.count - L.n
                parts[#parts + 1] = (EncodeSegment(L, 1, L.n, false, false))
            else
                removed = removed + seg.count
            end
        else
            parts[#parts + 1] = SegmentString(item, seg)
        end
    end
    if removed == 0 then return s, 0 end
    if #parts == 0 then return nil, removed end
    return Assemble(item.m, item.ref7, parts), removed
end

-- Re-stores sealed blocks to match the compression setting: compresses raw
-- sealed blocks (if useful) or unpacks compressed ones. Returns newString, changed.
function Codec.Repack(s, compress)
    local item = Codec.Parse(s)
    if not item then return s, false end
    local parts, changed = {}, false
    for i, seg in ipairs(item.segs) do
        local done = false
        if not IsTail(item, i) and ((compress and seg.kind == 0) or (not compress and seg.kind == 1)) then
            local L = NewList()
            if DecodeSegment(item, seg, L) and L.n == seg.count then
                local str = EncodeSegment(L, 1, L.n, true, compress)
                if str ~= SegmentString(item, seg) then
                    parts[#parts + 1] = str
                    changed, done = true, true
                end
            end
        end
        if not done then parts[#parts + 1] = SegmentString(item, seg) end
    end
    if not changed then return s, false end
    return Assemble(item.m, item.ref7, parts), true
end
