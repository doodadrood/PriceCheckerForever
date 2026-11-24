local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.Consensus = {}

local SYNC_PREFIX = "PCF_SYNC"
local SIX_HOURS_SECONDS = 6 * 3600
local TWENTY_FOUR_HOURS_SECONDS = 24 * 3600
local SEVEN_DAYS_SECONDS = 7 * 86400
local PRE_CLAIM_GRACE_SECONDS = 0.5 -- suppress if a peer's bid/reply arrived right around the query event
local BID_TTL_SECONDS = 15.0        -- discard old peer bids after this many seconds
local SETTLE_WINDOW_SECONDS = 0.65  -- wait after broadcasting BID so concurrent peer BIDs resolve deterministically

-- Priority tiers (lower = higher priority / answers earlier)
local TIER_TSM_FRESH = 1 -- TSM DBMarket (live/un-timestamped or < 6h)
local TIER_AH_FRESH  = 2 -- Auctionator / Native / Sniff / Mesh (< 6h, ordered by recency)
local TIER_AH_AGING  = 3 -- Any AH data 6h..24h old (including timestamped stale TSM)
local TIER_AH_STALE  = 4 -- Any AH data >= 24h old
local TIER_VENDOR    = 5 -- Vendor-price-only nodes yield to nodes holding real AH data
local TIER_NO_DATA   = 6 -- Nodes with nothing yield to everyone; only answer if nobody else did

-- [itemId] = GetTime() (local clock) at which a claim was made or seen.
-- Claims are keyed by itemId only: GetTime() differs on every machine, so it must never
-- be part of anything compared across clients.
local activeClaims = {}

-- [itemId] = { { tier, ageMin, roll, sender, receivedAt }, ... }
local activeBids = {}

-- [itemId] = { tier, ageMin, roll, sender, sentAt } for our own in-flight bid (secret-sender self-echo filter)
local pendingSelfBids = {}

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

local function NormalizeSenderName(name)
    if type(name) ~= "string" or IsSecret(name) then return "" end
    local ok, shortName = pcall(function()
        return (name:match("^([^%-]+)") or name):lower()
    end)
    if ok and type(shortName) == "string" then
        return shortName
    end
    return ""
end

local function IsSelfSender(sender)
    if not sender or IsSecret(sender) then return false end
    local playerName = UnitName and UnitName("player")
    if not playerName or IsSecret(playerName) then return false end
    local normSender = NormalizeSenderName(sender)
    local normPlayer = NormalizeSenderName(playerName)
    return normSender ~= "" and normSender == normPlayer
end

local function ParseAddonMessage(message)
    if type(message) ~= "string" or IsSecret(message) then return nil, nil end
    local ok, action, payload = pcall(function()
        return message:match("^([^:]+):(.+)$")
    end)
    if ok then
        return action, payload
    end
    return nil, nil
end

local function ParseAgeSecondsFromSource(source)
    if type(source) ~= "string" then return nil end
    local h, m = source:match("%((%d+)h%s+(%d+)m%s+ago%)")
    if h and m then
        return (tonumber(h) * 3600) + (tonumber(m) * 60)
    end
    local d = source:match("%((%d+)d%s+ago%)")
    if d then
        return tonumber(d) * 86400
    end
    local hoursOnly = source:match("%((%d+)h%s+ago%)")
    if hoursOnly then
        return tonumber(hoursOnly) * 3600
    end
    local minsOnly = source:match("%((%d+)m%s+ago%)")
    if minsOnly then
        return tonumber(minsOnly) * 60
    end
    return nil
end

local function ResolveDataAgeSeconds(itemId, source, timestamp)
    if type(timestamp) == "number" and timestamp > 0 and timestamp < math.huge and timestamp == timestamp then
        return math.max(0, math.floor(time() - timestamp))
    end

    local parsedFromSource = ParseAgeSecondsFromSource(source)
    if parsedFromSource ~= nil then
        return math.max(0, math.floor(parsedFromSource))
    end

    local isExternal = type(source) == "string" and (source:find("^TSM") ~= nil or source:find("^Auctionator") ~= nil)
    if not isExternal and itemId and PCF_DB and PCF_DB.prices and PCF_DB.prices[itemId] then
        local lastUpdated = PCF_DB.prices[itemId].lastUpdated
        if type(lastUpdated) == "number" and lastUpdated > 0 and lastUpdated < math.huge then
            return math.max(0, math.floor(time() - lastUpdated))
        end
    end

    return nil
end

-- Computes deterministic (tier, ageSec, ageMin) quality ranking for an item response.
-- Lower tier = higher priority; within a tier, lower ageMin = fresher data.
function PCF.Consensus.ComputeQuality(itemId, source, timestamp)
    if source == nil or source == "No Data" then
        return TIER_NO_DATA, 0, 0
    end
    if type(source) == "string" and source:find("^Vendor") then
        return TIER_VENDOR, 0, 0
    end

    local isTSM = type(source) == "string" and source:find("^TSM") ~= nil
    local isAuctionator = type(source) == "string" and source:find("^Auctionator") ~= nil
    local ageSec = ResolveDataAgeSeconds(itemId, source, timestamp)

    if isTSM then
        -- Un-timestamped TSM DBMarket is maintained by TSM Desktop App: treat as Tier 1 live data.
        -- If TSM exposes an explicit stale timestamp (>= 6h), demote it just like other stale data.
        if ageSec == nil or ageSec < SIX_HOURS_SECONDS then
            local effectiveAge = ageSec or 0
            return TIER_TSM_FRESH, effectiveAge, math.floor(effectiveAge / 60)
        elseif ageSec < TWENTY_FOUR_HOURS_SECONDS then
            return TIER_AH_AGING, ageSec, math.floor(ageSec / 60)
        else
            return TIER_AH_STALE, ageSec, math.floor(ageSec / 60)
        end
    end

    if ageSec == nil then
        -- Auctionator without a timestamp defaults to 1h (yields to TSM and fresher scans);
        -- untimestamped Native/other entries are treated as stale.
        ageSec = isAuctionator and 3600 or TWENTY_FOUR_HOURS_SECONDS
    end

    local ageMin = math.floor(ageSec / 60)
    if ageSec < SIX_HOURS_SECONDS then
        return TIER_AH_FRESH, ageSec, ageMin
    elseif ageSec < TWENTY_FOUR_HOURS_SECONDS then
        return TIER_AH_AGING, ageSec, ageMin
    end
    return TIER_AH_STALE, ageSec, ageMin
end

-- Computes initial pre-BID wait delay in seconds based on tier and age.
-- Strictly separates tiers so TSM answers first, fresher AH scans beat older ones,
-- very stale scans (>= 24h) wait well behind fresh data, and Vendor/No Data wait last.
local function ComputeBidDelay(tier, ageSec)
    if tier == TIER_TSM_FRESH then
        return 0.05 + (math.random(0, 100) / 1000)
    elseif tier == TIER_AH_FRESH then
        local ageFrac = math.min(1.0, math.max(0, ageSec or 0) / SIX_HOURS_SECONDS)
        return 0.90 + (ageFrac * 1.10) + (math.random(0, 150) / 1000)
    elseif tier == TIER_AH_AGING then
        local ageFrac = math.min(1.0, math.max(0, (ageSec or SIX_HOURS_SECONDS) - SIX_HOURS_SECONDS) / (TWENTY_FOUR_HOURS_SECONDS - SIX_HOURS_SECONDS))
        return 2.40 + (ageFrac * 0.80) + (math.random(0, 200) / 1000)
    elseif tier == TIER_AH_STALE then
        local ageFrac = math.min(1.0, math.max(0, (ageSec or TWENTY_FOUR_HOURS_SECONDS) - TWENTY_FOUR_HOURS_SECONDS) / (SEVEN_DAYS_SECONDS - TWENTY_FOUR_HOURS_SECONDS))
        return 3.50 + (ageFrac * 0.70) + (math.random(0, 250) / 1000)
    elseif tier == TIER_VENDOR then
        return 4.60 + (math.random(0, 400) / 1000)
    end
    return 5.40 + (math.random(0, 800) / 1000)
end

local function IsClaimedForQuery(itemId, queryTime)
    local claimedAt = activeClaims[itemId]
    if not claimedAt then
        return false
    end
    -- Claimed while our backoff timer was waiting, or within the grace window right before the query
    if claimedAt >= (queryTime - PRE_CLAIM_GRACE_SECONDS) then
        return true
    end
    return false
end

local function RecordPeerBid(itemId, tier, ageMin, roll, senderName, receivedAt)
    local list = activeBids[itemId]
    if not list then
        list = {}
        activeBids[itemId] = list
    else
        local cutoff = receivedAt - BID_TTL_SECONDS
        for i = #list, 1, -1 do
            if list[i].receivedAt < cutoff then
                table.remove(list, i)
            end
        end
    end
    table.insert(list, {
        tier = tier,
        ageMin = ageMin,
        roll = roll,
        sender = senderName or "",
        receivedAt = receivedAt,
    })
end

-- Checked BEFORE we broadcast a BID: yield silently if a peer already bid with equal or better data quality.
local function HasEqualOrBetterPeerBid(itemId, queryTime, myTier, myAgeMin)
    local list = activeBids[itemId]
    if not list then return false end
    local minTime = queryTime - PRE_CLAIM_GRACE_SECONDS
    for i = 1, #list do
        local bid = list[i]
        if bid.receivedAt >= minTime then
            if bid.tier < myTier or (bid.tier == myTier and bid.ageMin <= myAgeMin) then
                return true
            end
        end
    end
    return false
end

-- Checked AFTER we broadcast a BID (at end of settle window): strict total order guarantees
-- exactly one winner even when multiple peers broadcast concurrent BIDs in the same tier.
local function HasWinningPeerBid(itemId, queryTime, myBid)
    local list = activeBids[itemId]
    if not list then return false end
    local minTime = queryTime - PRE_CLAIM_GRACE_SECONDS
    for i = 1, #list do
        local bid = list[i]
        if bid.receivedAt >= minTime then
            if bid.tier ~= myBid.tier then
                if bid.tier < myBid.tier then return true end
            elseif bid.ageMin ~= myBid.ageMin then
                if bid.ageMin < myBid.ageMin then return true end
            elseif bid.roll ~= myBid.roll then
                if bid.roll < myBid.roll then return true end
            elseif bid.sender ~= myBid.sender then
                if bid.sender < myBid.sender then return true end
            end
        end
    end
    return false
end

-- Accepts "<itemId>" and the legacy "<itemId>_<timeBucket>" payload from older versions.
local function ParseClaimItemId(payload)
    if type(payload) ~= "string" or IsSecret(payload) then return nil end
    local ok, res = pcall(function()
        return tonumber(payload:match("^(%d+)"))
    end)
    if ok then
        return res
    end
    return nil
end

local function ParseBidPayload(payload)
    if type(payload) ~= "string" or IsSecret(payload) then return nil end
    local ok, idStr, tierStr, ageStr, rollStr = pcall(function()
        return payload:match("^(%d+):(%d+):(%d+):(%d+)$")
    end)
    if not ok or not idStr then return nil end
    local bidItemId = tonumber(idStr)
    local bidTier = tonumber(tierStr)
    local bidAgeMin = tonumber(ageStr)
    local bidRoll = tonumber(rollStr)
    if bidItemId and bidItemId > 0 and bidTier and bidTier >= 1 and bidAgeMin and bidAgeMin >= 0 and bidRoll and bidRoll >= 0 then
        return bidItemId, bidTier, bidAgeMin, bidRoll
    end
    return nil
end

function PCF.Consensus.Init()
    if PCF.Consensus._initialized then return end
    PCF.Consensus._initialized = true

    RegisterPrefix(SYNC_PREFIX)
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
        if IsSecret(prefix) or prefix ~= SYNC_PREFIX then return end
        if message == nil or IsSecret(message) then return end
        local action, payload = ParseAddonMessage(message)
        if action == "CLAIM" then
            local claimedItemId = ParseClaimItemId(payload)
            if claimedItemId then
                activeClaims[claimedItemId] = GetTime()
            end
        elseif action == "BID" then
            local bidItemId, bidTier, bidAgeMin, bidRoll = ParseBidPayload(payload)
            if not bidItemId then return end

            -- Ignore our own BID echo (supports both normal and secret-sender dungeon contexts)
            if sender ~= nil and not IsSecret(sender) then
                if IsSelfSender(sender) then return end
            else
                local selfBid = pendingSelfBids[bidItemId]
                if selfBid and selfBid.tier == bidTier and selfBid.ageMin == bidAgeMin and selfBid.roll == bidRoll then
                    return
                end
            end

            RecordPeerBid(bidItemId, bidTier, bidAgeMin, bidRoll, NormalizeSenderName(sender), GetTime())
        end
    end)
    PCF.Consensus.frame = frame
end

function PCF.Consensus.ResetClaims()
    activeClaims = {}
    activeBids = {}
    pendingSelfBids = {}
end

-- Records that someone else already answered for this item (e.g. seen in guild chat).
function PCF.Consensus.RegisterClaim(itemId)
    itemId = tonumber(itemId)
    if itemId and itemId > 0 then
        activeClaims[itemId] = GetTime()
    end
end

function PCF.Consensus.DispatchGuildResponse(itemId, dispatchCallback, source, timestamp)
    itemId = tonumber(itemId)
    if not itemId or itemId <= 0 then return end

    local queryTime = GetTime()
    if IsClaimedForQuery(itemId, queryTime) then
        return -- Already claimed by another node for this query
    end

    local tier, ageSec, ageMin = PCF.Consensus.ComputeQuality(itemId, source, timestamp)
    if HasEqualOrBetterPeerBid(itemId, queryTime, tier, ageMin) then
        return -- A peer with equal or better data already bid for this query
    end

    local bidDelay = ComputeBidDelay(tier, ageSec)
    local myRoll = math.random(1, 999999)
    local mySender = NormalizeSenderName(UnitName and UnitName("player"))

    C_Timer.After(bidDelay, function()
        if IsClaimedForQuery(itemId, queryTime) then
            return
        end
        if HasEqualOrBetterPeerBid(itemId, queryTime, tier, ageMin) then
            return
        end

        local myBid = {
            tier = tier,
            ageMin = ageMin,
            roll = myRoll,
            sender = mySender,
            sentAt = GetTime(),
        }
        pendingSelfBids[itemId] = myBid
        SendAddonMsg(SYNC_PREFIX, string.format("BID:%.0f:%d:%.0f:%.0f", itemId, tier, ageMin, myRoll), "GUILD")

        C_Timer.After(SETTLE_WINDOW_SECONDS, function()
            if pendingSelfBids[itemId] == myBid then
                pendingSelfBids[itemId] = nil
            end
            if IsClaimedForQuery(itemId, queryTime) then
                return
            end
            if HasWinningPeerBid(itemId, queryTime, myBid) then
                return
            end

            -- Broadcast claim to suppress other guild members waiting on this query
            activeClaims[itemId] = GetTime()
            SendAddonMsg(SYNC_PREFIX, string.format("CLAIM:%.0f", itemId), "GUILD")
            dispatchCallback()
        end)
    end)
end
