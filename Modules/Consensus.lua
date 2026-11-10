local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.Consensus = {}

local SYNC_PREFIX = "PCF_SYNC"
local SIX_HOURS_SECONDS = 6 * 3600
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

local function ParseClaimMessage(message)
    if type(message) ~= "string" then return nil, nil end
    if strsplit then
        return strsplit(":", message)
    end
    return message:match("^([^:]+):(.+)$")
end

local function ComputeFreshnessPenalty(itemId, source)
    if source == "TSM DBMarket" or source == "Auctionator" then
        return 0.00
    end
    if itemId and PCF_DB and PCF_DB.prices and PCF_DB.prices[itemId] then
        local lastUpdated = PCF_DB.prices[itemId].lastUpdated or 0
        if (time() - lastUpdated) < SIX_HOURS_SECONDS then
            return 0.00
        end
    end
    return 0.20
end

function PCF.Consensus.Init()
    RegisterPrefix(SYNC_PREFIX)
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
        if prefix ~= SYNC_PREFIX then return end
        local action, hash = ParseClaimMessage(message)
        if action == "CLAIM" and hash then
            activeClaims[hash] = true
        end
    end)
    PCF.Consensus.frame = frame
end

function PCF.Consensus.ResetClaims()
    activeClaims = {}
end

function PCF.Consensus.DispatchGuildResponse(itemId, dispatchCallback, source)
    -- Hash key based on ItemID and a 60-second time slice
    local timeBucket = math.floor(GetTime() / 60)
    local hash = string.format("%d_%d", itemId, timeBucket)

    if activeClaims[hash] then
        return -- Already claimed by another node
    end

    -- Delay = FreshnessPenalty (0.00s or 0.20s) + RandomJitter (0.050s to 0.200s)
    local freshnessPenalty = ComputeFreshnessPenalty(itemId, source)
    local randomJitter = math.random(50, 200) / 1000
    local delay = freshnessPenalty + randomJitter

    C_Timer.After(delay, function()
        if not activeClaims[hash] then
            -- Broadcast claim to suppress other guild members
            activeClaims[hash] = true
            SendAddonMsg(SYNC_PREFIX, "CLAIM:" .. hash, "GUILD")
            dispatchCallback()
        end
    end)
end
