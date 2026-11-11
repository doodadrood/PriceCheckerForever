local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.Consensus = {}

local SYNC_PREFIX = "PCF_SYNC"
local SIX_HOURS_SECONDS = 6 * 3600
local CLAIM_WINDOW_SECONDS = 60 -- how long a claim on an item suppresses other responders
local VENDOR_ONLY_DELAY = 2.0   -- vendor-price-only nodes yield to nodes holding real AH data
local NO_DATA_DELAY = 3.0       -- nodes with nothing yield to everyone; they only answer if nobody else did

-- [itemId] = GetTime() (local clock) at which a claim was made or seen.
-- Claims are keyed by itemId only: GetTime() differs on every machine, so it must never
-- be part of anything compared across clients.
local activeClaims = {}

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

local function ParseClaimMessage(message)
    if type(message) ~= "string" or IsSecret(message) then return nil, nil end
    local ok, action, payload = pcall(function()
        if strsplit then
            return strsplit(":", message)
        end
        return message:match("^([^:]+):(.+)$")
    end)
    if ok then
        return action, payload
    end
    return nil, nil
end

local function ComputeFreshnessPenalty(itemId, source)
    if type(source) == "string" and (source:find("^TSM") or source:find("^Auctionator")) then
        return 0.00
    end
    if itemId and PCF_DB and PCF_DB.prices and PCF_DB.prices[itemId] then
        local lastUpdated = PCF_DB.prices[itemId].lastUpdated or 0
        if (time() - lastUpdated) < SIX_HOURS_SECONDS then
            return 0.00
        end
    end
    return 1.00 -- stale data: yield to nodes with fresh data
end

-- Lower delay = answers first. Real AH data beats vendor-only data, which beats "No Data".
local function ComputeResponseDelay(itemId, source)
    if source == nil or source == "No Data" then
        -- Wide spread so the first responder's CLAIM reaches the others before they fire
        return NO_DATA_DELAY + (math.random(0, 2000) / 1000)
    end
    if type(source) == "string" and source:find("^Vendor") then
        return VENDOR_ONLY_DELAY + (math.random(0, 1000) / 1000)
    end
    return ComputeFreshnessPenalty(itemId, source) + (math.random(50, 1000) / 1000)
end

local function IsClaimed(itemId)
    local claimedAt = activeClaims[itemId]
    if not claimedAt then
        return false
    end
    if (GetTime() - claimedAt) < CLAIM_WINDOW_SECONDS then
        return true
    end
    activeClaims[itemId] = nil
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

function PCF.Consensus.Init()
    if PCF.Consensus._initialized then return end
    PCF.Consensus._initialized = true

    RegisterPrefix(SYNC_PREFIX)
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
        if prefix ~= SYNC_PREFIX then return end
        if message == nil or IsSecret(message) then return end
        local action, payload = ParseClaimMessage(message)
        if action == "CLAIM" then
            local claimedItemId = ParseClaimItemId(payload)
            if claimedItemId then
                activeClaims[claimedItemId] = GetTime()
            end
        end
    end)
    PCF.Consensus.frame = frame
end

function PCF.Consensus.ResetClaims()
    activeClaims = {}
end

-- Records that someone else already answered for this item (e.g. seen in guild chat).
function PCF.Consensus.RegisterClaim(itemId)
    itemId = tonumber(itemId)
    if itemId and itemId > 0 then
        activeClaims[itemId] = GetTime()
    end
end

function PCF.Consensus.DispatchGuildResponse(itemId, dispatchCallback, source)
    if IsClaimed(itemId) then
        return -- Already claimed by another node
    end

    local delay = ComputeResponseDelay(itemId, source)

    C_Timer.After(delay, function()
        if not IsClaimed(itemId) then
            -- Broadcast claim to suppress other guild members
            activeClaims[itemId] = GetTime()
            SendAddonMsg(SYNC_PREFIX, "CLAIM:" .. itemId, "GUILD")
            dispatchCallback()
        end
    end)
end
