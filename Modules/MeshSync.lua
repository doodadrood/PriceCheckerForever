local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.MeshSync = {}

local SYNC_PREFIX = "PCF_SYNC"
local LEGACY_SYNC_PREFIX = "GPC_SYNC"
local EXTERNAL_PREFIXES = {
    TSM_SYNC = true,
    ATR_SYNC = true,
    Auctionator = true,
    AUX_SYNC = true,
}

local MAX_ADDON_MSG_BYTES = 245 -- Below Blizzard's 255-byte SendAddonMessage ceiling
local MAX_ITEMS_PER_CHUNK = 15
local MAX_SYNC_BUYOUT_COPPER = 100000000000 -- 10,000,000g (above WoW's 9,999,999g 99s 99c cap)
local DIGEST_COOLDOWN_SEC = 1800 -- 30 minutes minimum between REQ_DIGEST broadcasts
local HEARTBEAT_INTERVAL_SEC = 600 -- 10 minutes between dirty-item gossip broadcasts
local SEND_PACE_SEC = 0.20 -- 5 messages/sec max outbound drain rate
local MAX_EXTERNAL_REFRESH_BATCH = 200

local lastDigestRequestTime = -DIGEST_COOLDOWN_SEC
local pendingDigestReplyId = 0
local dirtyItems = {}
local dirtyCount = 0
local outboundQueue = {}
local queueHead = 1
local queueTail = 0
local queueDrainPending = false
local heartbeatPending = false
local recurringDigestScheduled = false

-- Targeted single-item sync ("REQ_ITEM:<itemId>") used when a guild price check hits an item
-- this node has no AH data for. Peers holding data answer with a normal DELTA for just that item.
local ITEM_REQUEST_COOLDOWN_SEC = 300 -- don't re-ask for the same item more often than this
local ITEM_REQUEST_SUPPRESS_SEC = 10  -- skip our request if a peer asked for the same item this recently
local ITEM_REPLY_DEDUPE_SEC = 30      -- don't answer the same item request twice within this window
local itemRequestSent = {}  -- [itemId] = GetTime() we last asked
local itemRequestSeen = {}  -- [itemId] = GetTime() we last saw a peer ask
local itemReplyToken = {}   -- [itemId] = counter; bumped when a peer's DELTA covers the item
local itemReplySent = {}    -- [itemId] = GetTime() we last answered

local function RegisterPrefix(prefix)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(prefix)
    elseif RegisterAddonMessagePrefix then
        RegisterAddonMessagePrefix(prefix)
    end
end

local function SendAddonMsg(prefix, message, channel)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(prefix, message, channel)
    elseif SendAddonMessage then
        SendAddonMessage(prefix, message, channel)
    end
end

local function IsSecret(val)
    if val == nil then return false end
    if PCF and PCF.IsSecret then
        return PCF.IsSecret(val)
    end
    if _G.issecretvalue then
        local ok, isSec = pcall(_G.issecretvalue, val)
        if ok and isSec then
            return true
        end
    end
    if _G.canaccessvalue then
        local ok, canAccess = pcall(_G.canaccessvalue, val)
        if ok and not canAccess then
            return true
        end
    end
    return false
end

local function IsSelfSender(sender)
    if not sender or IsSecret(sender) then return false end
    local playerName = UnitName and UnitName("player")
    if not playerName or IsSecret(playerName) then return false end
    local ok, isMatch = pcall(function()
        if sender == playerName then return true end
        local shortSender = sender:match("^([^%-]+)")
        return shortSender == playerName
    end)
    return ok and isMatch == true
end

local function DrainOutboundQueue()
    queueDrainPending = false
    if queueHead > queueTail then
        queueHead = 1
        queueTail = 0
        return
    end

    local msg = outboundQueue[queueHead]
    outboundQueue[queueHead] = nil
    queueHead = queueHead + 1

    if msg and PCF_DB and PCF_DB.settings and PCF_DB.settings.enablePeerSync ~= false then
        SendAddonMsg(SYNC_PREFIX, msg, "GUILD")
    end

    if queueHead <= queueTail then
        queueDrainPending = true
        C_Timer.After(SEND_PACE_SEC, DrainOutboundQueue)
    else
        queueHead = 1
        queueTail = 0
    end
end

local function EnqueueOutboundMessages(chunks, immediateFirst)
    if not chunks or #chunks == 0 then return end
    local startIndex = 1
    if immediateFirst and not queueDrainPending and queueHead > queueTail then
        SendAddonMsg(SYNC_PREFIX, chunks[1], "GUILD")
        startIndex = 2
    end
    for i = startIndex, #chunks do
        queueTail = queueTail + 1
        outboundQueue[queueTail] = chunks[i]
    end
    if queueHead <= queueTail and not queueDrainPending then
        queueDrainPending = true
        C_Timer.After(SEND_PACE_SEC, DrainOutboundQueue)
    end
end

-- Queries installed local TSM / Auctionator databases for known items in PCF_DB.prices
-- so TSM/Auctionator users keep their local cache and guild mesh continuously fresh.
function PCF.MeshSync.RefreshExternalAddonPrices()
    if not PCF_DB or not PCF_DB.prices then return 0 end
    if PCF_DB.settings and PCF_DB.settings.enableSniffExternalAddons == false then
        return 0
    end
    if not PCF.HasExternalAuctionAddon or not PCF.HasExternalAuctionAddon() then
        return 0
    end
    if not PCF.ProviderRegistry or not PCF.ProviderRegistry.ResolveAHPrice then
        return 0
    end

    local checked = 0
    local updated = 0
    for itemId, data in pairs(PCF_DB.prices) do
        if type(itemId) == "number" and itemId > 0 then
            local prevBuyout = data and data.minBuyout
            local price = PCF.ProviderRegistry.ResolveAHPrice(nil, itemId)
            if price and price > 0 and price ~= prevBuyout then
                updated = updated + 1
            end
            checked = checked + 1
            if checked >= MAX_EXTERNAL_REFRESH_BATCH then
                break
            end
        end
    end
    return updated
end

local function NormalizePositiveInt(val)
    if type(val) ~= "number" or not (val > 0 and val < math.huge) then
        return nil
    end
    local floored = math.floor(val)
    if not (floored > 0) then
        return nil
    end
    return floored + 0
end

local function NormalizeNonNegativeInt(val)
    if type(val) ~= "number" or not (val >= 0 and val < math.huge) then
        return nil
    end
    return math.floor(val) + 0
end

-- Packs price records into compact "DELTA:<itemId>:<buyout>:<timestamp>|..." chunks
-- strictly respecting the 255-character SendAddonMessage limit.
function PCF.MeshSync.BuildDeltaChunks(sinceTimestamp, itemFilter)
    if not PCF_DB or not PCF_DB.prices then return {} end
    sinceTimestamp = tonumber(sinceTimestamp) or 0
    if sinceTimestamp ~= sinceTimestamp then
        sinceTimestamp = 0
    end

    local chunks = {}
    local currentPrefix = "DELTA:"
    local currentLen = #currentPrefix
    local currentParts = {}
    local countInChunk = 0

    for itemId, data in pairs(PCF_DB.prices) do
        if (not itemFilter or itemFilter[itemId]) and type(data) == "table" then
            local safeItemId = NormalizePositiveInt(itemId)
            local safeBuyout = NormalizePositiveInt(data.minBuyout)
            local safeUpdated = NormalizeNonNegativeInt(data.lastUpdated or 0)

            if safeItemId and safeBuyout and safeUpdated and safeUpdated > sinceTimestamp then
                -- Use %.0f instead of %d: WoW Lua's %d overflows signed 32-bit int (>214,748g 36s 47c)
                local entryStr = string.format("%.0f:%.0f:%.0f", safeItemId, safeBuyout, safeUpdated)
                if (#currentPrefix + #entryStr) <= MAX_ADDON_MSG_BYTES then
                    local separatorLen = countInChunk > 0 and 1 or 0
                    local projectedLen = currentLen + separatorLen + #entryStr

                    if countInChunk > 0 and (projectedLen > MAX_ADDON_MSG_BYTES or countInChunk >= MAX_ITEMS_PER_CHUNK) then
                        table.insert(chunks, currentPrefix .. table.concat(currentParts, "|"))
                        currentParts = {}
                        currentLen = #currentPrefix
                        countInChunk = 0
                    end

                    table.insert(currentParts, entryStr)
                    currentLen = currentLen + (countInChunk > 0 and 1 or 0) + #entryStr
                    countInChunk = countInChunk + 1
                end
            end
        end
    end

    if countInChunk > 0 then
        table.insert(chunks, currentPrefix .. table.concat(currentParts, "|"))
    end

    return chunks
end

-- Parses a "DELTA:<itemId>:<buyout>:<timestamp>|..." payload and merges newer entries
function PCF.MeshSync.ApplyDeltaPayload(payload)
    if type(payload) ~= "string" then return 0 end
    local body = payload:match("^DELTA:(.+)$") or payload
    if not body or body == "" then return 0 end

    PCF_DB = PCF_DB or {}
    PCF_DB.prices = PCF_DB.prices or {}

    local now = time()
    local updatedCount = 0

    for itemIdStr, buyoutStr, tsStr in body:gmatch("(%d+):(%d+):(%d+)") do
        local itemId = tonumber(itemIdStr)
        local buyout = tonumber(buyoutStr)
        local ts = tonumber(tsStr)

        if itemId and itemId > 0 and itemId < math.huge and buyout and buyout > 0 and buyout < MAX_SYNC_BUYOUT_COPPER and ts and ts > 0 and ts < math.huge then
            -- Clamp peer timestamp against future clock skew
            local safeTs = math.min(ts, now)
            local existing = PCF_DB.prices[itemId]

            if not existing or safeTs > (existing.lastUpdated or 0) or (safeTs == existing.lastUpdated and buyout < existing.minBuyout) then
                if existing then
                    existing.minBuyout = buyout
                    existing.lastUpdated = safeTs
                    existing.source = "PCF Mesh"
                else
                    PCF_DB.prices[itemId] = {
                        minBuyout = buyout,
                        minBid = buyout,
                        lastUpdated = safeTs,
                        count = 1,
                        source = "PCF Mesh",
                    }
                end
                updatedCount = updatedCount + 1
            end

            if safeTs > (PCF_DB.lastPeerSync or 0) then
                PCF_DB.lastPeerSync = safeTs
            end
        end
    end

    return updatedCount
end

-- Passively inspects third-party addon messages for item price pairs without transmitting
function PCF.MeshSync.SniffExternalMessage(prefix, message, sender)
    if not PCF_DB or not PCF_DB.settings or PCF_DB.settings.enableSniffExternalAddons == false then
        return 0
    end
    if message == nil or IsSecret(message) or type(message) ~= "string" then
        return 0
    end
    local ok, len = pcall(function() return #message end)
    if not ok or not len or len > 512 then
        return 0
    end

    PCF_DB.prices = PCF_DB.prices or {}
    local now = time()
    local sniffedCount = 0

    for itemIdStr, buyoutStr in message:gmatch("(%d+):(%d+)") do
        local itemId = tonumber(itemIdStr)
        local buyout = tonumber(buyoutStr)
        if itemId and itemId > 0 and itemId < 500000 and buyout and buyout > 0 and buyout < MAX_SYNC_BUYOUT_COPPER then
            local existing = PCF_DB.prices[itemId]
            if not existing or now >= (existing.lastUpdated or 0) then
                if existing then
                    existing.minBuyout = buyout
                    existing.lastUpdated = now
                    existing.source = "PCF Sniff"
                else
                    PCF_DB.prices[itemId] = {
                        minBuyout = buyout,
                        minBid = buyout,
                        lastUpdated = now,
                        count = 1,
                        source = "PCF Sniff",
                    }
                end
                sniffedCount = sniffedCount + 1
            end
        end
    end

    return sniffedCount
end

local function FlushDirtyHeartbeat()
    heartbeatPending = false
    PCF.MeshSync.RefreshExternalAddonPrices()

    if dirtyCount == 0 then return end
    if not PCF_DB or not PCF_DB.settings or PCF_DB.settings.enablePeerSync == false then
        dirtyItems = {}
        dirtyCount = 0
        return
    end

    local filter = dirtyItems
    dirtyItems = {}
    dirtyCount = 0

    local chunks = PCF.MeshSync.BuildDeltaChunks(0, filter)
    EnqueueOutboundMessages(chunks, true)
end

function PCF.MeshSync.MarkDirty(itemId)
    if not itemId then return end
    if not dirtyItems[itemId] then
        dirtyItems[itemId] = true
        dirtyCount = dirtyCount + 1
    end
    if PCF.MeshSync.frame and not heartbeatPending then
        heartbeatPending = true
        local jitteredInterval = HEARTBEAT_INTERVAL_SEC + math.random(0, 300)
        C_Timer.After(jitteredInterval, FlushDirtyHeartbeat)
    end
end

-- Requests a delta digest from guild peers, enforcing a strict 30-minute cooldown
function PCF.MeshSync.RequestDigest(force)
    if not PCF_DB or not PCF_DB.settings or PCF_DB.settings.enablePeerSync == false then
        return false
    end

    local now = GetTime()
    if not force and (now - lastDigestRequestTime) < DIGEST_COOLDOWN_SEC then
        return false
    end

    lastDigestRequestTime = now
    local sinceTs = NormalizeNonNegativeInt(tonumber(PCF_DB and PCF_DB.lastPeerSync) or 0) or 0
    SendAddonMsg(SYNC_PREFIX, string.format("REQ_DIGEST:%.0f", sinceTs), "GUILD")
    return true
end

-- Asks guild peers for fresh data on one specific item (cheap alternative to a full digest).
function PCF.MeshSync.RequestItem(itemId)
    if not PCF_DB or not PCF_DB.settings or PCF_DB.settings.enablePeerSync == false then
        return false
    end
    itemId = NormalizePositiveInt(tonumber(itemId))
    if not itemId then
        return false
    end

    local now = GetTime()
    local lastSent = itemRequestSent[itemId]
    if lastSent and (now - lastSent) < ITEM_REQUEST_COOLDOWN_SEC then
        return false
    end
    itemRequestSent[itemId] = now

    -- Small random backoff: if several nodes lack the item, the first request covers everyone
    local backoff = 0.05 + (math.random(0, 250) / 1000)
    C_Timer.After(backoff, function()
        local seenAt = itemRequestSeen[itemId]
        if seenAt and (GetTime() - seenAt) < ITEM_REQUEST_SUPPRESS_SEC then
            return -- a peer already asked; their DELTA reply serves us too
        end
        SendAddonMsg(SYNC_PREFIX, string.format("REQ_ITEM:%.0f", itemId), "GUILD")
    end)
    return true
end

function PCF.MeshSync.ResetCooldowns()
    lastDigestRequestTime = -DIGEST_COOLDOWN_SEC
    pendingDigestReplyId = pendingDigestReplyId + 1
    dirtyItems = {}
    dirtyCount = 0
    outboundQueue = {}
    queueHead = 1
    queueTail = 0
    queueDrainPending = false
    heartbeatPending = false
    itemRequestSent = {}
    itemRequestSeen = {}
    itemReplyToken = {}
    itemReplySent = {}
end

local function HandleSyncMessage(prefix, message, channel, sender)
    if message == nil or IsSecret(message) then return end
    if IsSelfSender(sender) then return end

    if EXTERNAL_PREFIXES[prefix] then
        PCF.MeshSync.SniffExternalMessage(prefix, message, sender)
        return
    end

    if prefix ~= SYNC_PREFIX and prefix ~= LEGACY_SYNC_PREFIX then
        return
    end
    if not PCF_DB or not PCF_DB.settings or PCF_DB.settings.enablePeerSync == false then
        return
    end
    if type(message) ~= "string" then return end

    local sinceStr = message:match("^REQ_DIGEST:(%d+)$")
    if sinceStr then
        local sinceTs = tonumber(sinceStr) or 0
        pendingDigestReplyId = pendingDigestReplyId + 1
        local myReplyId = pendingDigestReplyId
        local backoff = 0.15 + (math.random(0, 450) / 1000)

        C_Timer.After(backoff, function()
            if pendingDigestReplyId ~= myReplyId then
                return -- Another peer already responded with a DELTA
            end
            PCF.MeshSync.RefreshExternalAddonPrices()
            local chunks = PCF.MeshSync.BuildDeltaChunks(sinceTs)
            if #chunks > 0 then
                dirtyItems = {}
                dirtyCount = 0
                EnqueueOutboundMessages(chunks, true)
            end
        end)
        return
    end

    local reqItemStr = message:match("^REQ_ITEM:(%d+)$")
    if reqItemStr then
        local reqItemId = NormalizePositiveInt(tonumber(reqItemStr))
        if not reqItemId then return end
        local now = GetTime()
        itemRequestSeen[reqItemId] = now

        local entry = PCF_DB.prices and PCF_DB.prices[reqItemId]
        if entry and entry.minBuyout and entry.minBuyout > 0 then
            local lastReply = itemReplySent[reqItemId]
            if lastReply and (now - lastReply) < ITEM_REPLY_DEDUPE_SEC then
                return
            end
            itemReplyToken[reqItemId] = (itemReplyToken[reqItemId] or 0) + 1
            local myToken = itemReplyToken[reqItemId]
            local backoff = 0.15 + (math.random(0, 450) / 1000)

            C_Timer.After(backoff, function()
                if itemReplyToken[reqItemId] ~= myToken then
                    return -- another peer already answered with a DELTA covering this item
                end
                itemReplySent[reqItemId] = GetTime()
                local chunks = PCF.MeshSync.BuildDeltaChunks(0, { [reqItemId] = true })
                EnqueueOutboundMessages(chunks, true)
            end)
        end
        return
    end

    if message:find("^DELTA:") then
        -- Suppress our pending digest election timer if another peer is already answering
        pendingDigestReplyId = pendingDigestReplyId + 1
        -- ...and any pending single-item answers this DELTA already covers
        for idStr in message:gmatch("(%d+):%d+:%d+") do
            local coveredId = tonumber(idStr)
            if coveredId and itemReplyToken[coveredId] then
                itemReplyToken[coveredId] = itemReplyToken[coveredId] + 1
            end
        end
        PCF.MeshSync.ApplyDeltaPayload(message)
    end
end

local function ScheduleRecurringDigestCycle()
    local interval = DIGEST_COOLDOWN_SEC + math.random(5, 60)
    C_Timer.After(interval, function()
        PCF.MeshSync.RequestDigest(false)
        ScheduleRecurringDigestCycle()
    end)
end

function PCF.MeshSync.Init()
    if PCF.MeshSync._initialized then return end
    PCF.MeshSync._initialized = true

    RegisterPrefix(SYNC_PREFIX)
    RegisterPrefix(LEGACY_SYNC_PREFIX)
    for extPrefix in pairs(EXTERNAL_PREFIXES) do
        RegisterPrefix(extPrefix)
    end

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
        HandleSyncMessage(prefix, message, channel, sender)
    end)
    PCF.MeshSync.frame = frame

    -- Jittered initial digest request (30-90 seconds after init) + recurring 30m cycle
    if not recurringDigestScheduled then
        recurringDigestScheduled = true
        local loginDelay = math.random(30, 90)
        C_Timer.After(loginDelay, function()
            PCF.MeshSync.RequestDigest(false)
            ScheduleRecurringDigestCycle()
        end)
    end
end
